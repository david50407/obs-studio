#include <stdlib.h>
#include <obs-module.h>
#include <util/threading.h>
#include <pthread.h>

#import <CoreGraphics/CGDisplayStream.h>
#import <Cocoa/Cocoa.h>

struct display_capture {
	obs_source_t source;

	samplerstate_t sampler;
	effect_t draw_effect;
	texture_t tex;

	unsigned display;
	uint32_t width, height;
	bool hide_cursor;

	os_event_t disp_finished;
	CGDisplayStreamRef disp;
	IOSurfaceRef current, prev;

	pthread_mutex_t mutex;
};

static void destroy_display_stream(struct display_capture *dc)
{
	if (dc->disp) {
		CGDisplayStreamStop(dc->disp);
		os_event_wait(dc->disp_finished);
	}

	if (dc->tex) {
		texture_destroy(dc->tex);
		dc->tex = NULL;
	}

	if (dc->current) {
		IOSurfaceDecrementUseCount(dc->current);
		CFRelease(dc->current);
		dc->current = NULL;
	}

	if (dc->prev) {
		IOSurfaceDecrementUseCount(dc->prev);
		CFRelease(dc->prev);
		dc->prev = NULL;
	}

	if (dc->disp) {
		CFRelease(dc->disp);
		dc->disp = NULL;
	}

	os_event_destroy(dc->disp_finished);
}

static void display_capture_destroy(void *data)
{
	struct display_capture *dc = data;

	if (!dc)
		return;

	gs_entercontext(obs_graphics());

	destroy_display_stream(dc);

	if (dc->sampler)
		samplerstate_destroy(dc->sampler);
	if (dc->draw_effect)
		effect_destroy(dc->draw_effect);

	gs_leavecontext();

	pthread_mutex_destroy(&dc->mutex);
	bfree(dc);
}

static inline void display_stream_update(struct display_capture *dc,
		CGDisplayStreamFrameStatus status, uint64_t display_time,
		IOSurfaceRef frame_surface, CGDisplayStreamUpdateRef update_ref)
{
	UNUSED_PARAMETER(display_time);
	UNUSED_PARAMETER(update_ref);

	if (status == kCGDisplayStreamFrameStatusStopped) {
		os_event_signal(dc->disp_finished);
		return;
	}

	IOSurfaceRef prev_current = NULL;

	if (frame_surface && !pthread_mutex_lock(&dc->mutex)) {
		prev_current = dc->current;
		dc->current = frame_surface;
		CFRetain(dc->current);
		IOSurfaceIncrementUseCount(dc->current);
		pthread_mutex_unlock(&dc->mutex);
	}

	if (prev_current) {
		IOSurfaceDecrementUseCount(prev_current);
		CFRelease(prev_current);
	}

	size_t dropped_frames = CGDisplayStreamUpdateGetDropCount(update_ref);
	if (dropped_frames > 0)
		blog(LOG_INFO, "%s: Dropped %zu frames",
				obs_source_getname(dc->source), dropped_frames);
}

static bool init_display_stream(struct display_capture *dc)
{
	if (dc->display >= [NSScreen screens].count)
		return false;

	NSScreen *screen = [NSScreen screens][dc->display];

	NSRect frame = [screen convertRectToBacking:screen.frame];

	dc->width = frame.size.width;
	dc->height = frame.size.height;

	NSNumber *screen_num = screen.deviceDescription[@"NSScreenNumber"];
	CGDirectDisplayID disp_id = (CGDirectDisplayID)screen_num.pointerValue;

	NSDictionary *rect_dict = CFBridgingRelease(
			CGRectCreateDictionaryRepresentation(
				CGRectMake(0, 0,
					screen.frame.size.width,
					screen.frame.size.height)));

	NSDictionary *dict = @{
		(__bridge NSString*)kCGDisplayStreamSourceRect: rect_dict,
		(__bridge NSString*)kCGDisplayStreamQueueDepth: @5,
		(__bridge NSString*)kCGDisplayStreamShowCursor:
			@(!dc->hide_cursor),
	};

	os_event_init(&dc->disp_finished, OS_EVENT_TYPE_MANUAL);

	dc->disp = CGDisplayStreamCreateWithDispatchQueue(disp_id,
			dc->width, dc->height, 'BGRA',
			(__bridge CFDictionaryRef)dict,
			dispatch_queue_create(NULL, NULL),
			^(CGDisplayStreamFrameStatus status,
				uint64_t displayTime,
				IOSurfaceRef frameSurface,
				CGDisplayStreamUpdateRef updateRef)
			{
				display_stream_update(dc, status, displayTime,
					frameSurface, updateRef);
			}
	);

	return !CGDisplayStreamStart(dc->disp);
}

static void *display_capture_create(obs_data_t settings,
		obs_source_t source)
{
	UNUSED_PARAMETER(source);
	UNUSED_PARAMETER(settings);

	struct display_capture *dc = bzalloc(sizeof(struct display_capture));

	dc->source = source;

	gs_entercontext(obs_graphics());

	struct gs_sampler_info info = {
		.filter = GS_FILTER_LINEAR,
		.address_u = GS_ADDRESS_CLAMP,
		.address_v = GS_ADDRESS_CLAMP,
		.address_w = GS_ADDRESS_CLAMP,
		.max_anisotropy = 1,
	};
	dc->sampler = gs_create_samplerstate(&info);
	if (!dc->sampler)
		goto fail;

	char *effect_file = obs_find_module_file(
			"mac-capture", "draw_rect.effect");
	dc->draw_effect = gs_create_effect_from_file(effect_file, NULL);
	bfree(effect_file);
	if (!dc->draw_effect)
		goto fail;

	gs_leavecontext();

	dc->display = obs_data_getint(settings, "display");
	pthread_mutex_init(&dc->mutex, NULL);

	if (!init_display_stream(dc))
		goto fail;

	return dc;

fail:
	gs_leavecontext();
	display_capture_destroy(dc);
	return NULL;
}

static void display_capture_video_tick(void *data, float seconds)
{
	UNUSED_PARAMETER(seconds);

	struct display_capture *dc = data;

	if (!dc->current)
		return;

	IOSurfaceRef prev_prev = dc->prev;
	if (pthread_mutex_lock(&dc->mutex))
		return;
	dc->prev = dc->current;
	dc->current = NULL;
	pthread_mutex_unlock(&dc->mutex);

	if (prev_prev == dc->prev)
		return;

	gs_entercontext(obs_graphics());
	if (dc->tex)
		texture_rebind_iosurface(dc->tex, dc->prev);
	else
		dc->tex = gs_create_texture_from_iosurface(dc->prev);
	gs_leavecontext();

	if (prev_prev) {
		IOSurfaceDecrementUseCount(prev_prev);
		CFRelease(prev_prev);
	}
}

static void display_capture_video_render(void *data, effect_t effect)
{
	UNUSED_PARAMETER(effect);

	struct display_capture *dc = data;

	if (!dc->tex)
		return;

	gs_load_samplerstate(dc->sampler, 0);
	technique_t tech = effect_gettechnique(dc->draw_effect, "Default");
	effect_settexture(effect_getparambyidx(dc->draw_effect, 1),
			dc->tex);
	technique_begin(tech);
	technique_beginpass(tech, 0);

	gs_draw_sprite(dc->tex, 0, 0, 0);

	technique_endpass(tech);
	technique_end(tech);
}

static const char *display_capture_getname(void)
{
	return obs_module_text("DisplayCapture");
}

static uint32_t display_capture_getwidth(void *data)
{
	struct display_capture *dc = data;
	return dc->width;
}

static uint32_t display_capture_getheight(void *data)
{
	struct display_capture *dc = data;
	return dc->height;
}

static void display_capture_defaults(obs_data_t settings)
{
	obs_data_set_default_int(settings, "display", 0);
	obs_data_set_default_bool(settings, "show_cursor", true);
}

static void display_capture_update(void *data, obs_data_t settings)
{
	struct display_capture *dc = data;
	unsigned display = obs_data_getint(settings, "display");
	bool show_cursor = obs_data_getbool(settings, "show_cursor");
	if (dc->display == display && dc->hide_cursor != show_cursor)
		return;

	gs_entercontext(obs_graphics());

	destroy_display_stream(dc);
	dc->display = display;
	dc->hide_cursor = !show_cursor;
	init_display_stream(dc);

	gs_leavecontext();
}

static obs_properties_t display_capture_properties(void)
{
	obs_properties_t props = obs_properties_create();

	obs_property_t list = obs_properties_add_list(props,
			"display", obs_module_text("DisplayCapture.Display"),
			OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);

	for (unsigned i = 0; i < [NSScreen screens].count; i++) {
		char buf[10];
		sprintf(buf, "%u", i);
		obs_property_list_add_int(list, buf, i);
	}

	obs_properties_add_bool(props, "show_cursor",
			obs_module_text("DisplayCapture.ShowCursor"));

	return props;
}

struct obs_source_info display_capture_info = {
	.id           = "display_capture",
	.type         = OBS_SOURCE_TYPE_INPUT,
	.getname      = display_capture_getname,

	.create       = display_capture_create,
	.destroy      = display_capture_destroy,

	.output_flags = OBS_SOURCE_VIDEO | OBS_SOURCE_CUSTOM_DRAW,
	.video_tick   = display_capture_video_tick,
	.video_render = display_capture_video_render,

	.getwidth     = display_capture_getwidth,
	.getheight    = display_capture_getheight,

	.defaults     = display_capture_defaults,
	.properties   = display_capture_properties,
	.update       = display_capture_update,
};
