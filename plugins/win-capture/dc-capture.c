#include "dc-capture.h"

#define WIN32_MEAN_AND_LEAN
#include <windows.h>

static inline void init_textures(struct dc_capture *capture)
{
	for (int i = 0; i < capture->num_textures; i++) {
		if (capture->compatibility)
			capture->textures[i] = gs_create_texture(
					capture->width, capture->height,
					GS_BGRA, 1, NULL, GS_DYNAMIC);
		else
			capture->textures[i] = gs_create_gdi_texture(
					capture->width, capture->height);

		if (!capture->textures[i]) {
			blog(LOG_WARNING, "[dc_capture_init] Failed to "
			                  "create textures");
			return;
		}
	}

	capture->valid = true;
}

void dc_capture_init(struct dc_capture *capture, int x, int y,
		uint32_t width, uint32_t height, bool cursor,
		bool compatibility)
{
	memset(capture, 0, sizeof(struct dc_capture));

	capture->x              = x;
	capture->y              = y;
	capture->width          = width;
	capture->height         = height;
	capture->capture_cursor = cursor;

	gs_entercontext(obs_graphics());

	if (!gs_gdi_texture_available())
		compatibility = true;

	capture->compatibility = compatibility;
	capture->num_textures  = compatibility ? 1 : 2;

	init_textures(capture);

	gs_leavecontext();

	if (!capture->valid)
		return;

	if (compatibility) {
		BITMAPINFO bi = {0};
		BITMAPINFOHEADER *bih = &bi.bmiHeader;
		bih->biSize     = sizeof(BITMAPINFOHEADER);
		bih->biBitCount = 32;
		bih->biWidth    = width;
		bih->biHeight   = height;
		bih->biPlanes   = 1;

		capture->hdc = CreateCompatibleDC(NULL);
		capture->bmp = CreateDIBSection(capture->hdc, &bi,
				DIB_RGB_COLORS, (void**)&capture->bits,
				NULL, 0);
		capture->old_bmp = SelectObject(capture->hdc, capture->bmp);
	}
}

void dc_capture_free(struct dc_capture *capture)
{
	if (capture->hdc) {
		SelectObject(capture->hdc, capture->old_bmp);
		DeleteDC(capture->hdc);
		DeleteObject(capture->bmp);
	}

	gs_entercontext(obs_graphics());

	for (int i = 0; i < capture->num_textures; i++)
		texture_destroy(capture->textures[i]);

	gs_leavecontext();

	memset(capture, 0, sizeof(struct dc_capture));
}

static void draw_cursor(struct dc_capture *capture, HDC hdc, HWND window)
{
	HICON      icon;
	ICONINFO   ii;
	CURSORINFO *ci = &capture->ci;
	POINT      win_pos = {capture->x, capture->y};

	if (!(capture->ci.flags & CURSOR_SHOWING))
		return;

	icon = CopyIcon(capture->ci.hCursor);
	if (!icon)
		return;

	if (GetIconInfo(icon, &ii)) {
		POINT pos;

		if (window)
			ClientToScreen(window, &win_pos);

		pos.x = ci->ptScreenPos.x - (int)ii.xHotspot - win_pos.x;
		pos.y = ci->ptScreenPos.y - (int)ii.yHotspot - win_pos.y;

		DrawIcon(hdc, pos.x, pos.y, icon);

		DeleteObject(ii.hbmColor);
		DeleteObject(ii.hbmMask);
	}

	DestroyIcon(icon);
}

static inline HDC dc_capture_get_dc(struct dc_capture *capture)
{
	if (!capture->valid)
		return NULL;

	if (capture->compatibility)
		return capture->hdc;
	else
		return texture_get_dc(capture->textures[capture->cur_tex]);
}

static inline void dc_capture_release_dc(struct dc_capture *capture)
{
	if (capture->compatibility) {
		texture_setimage(capture->textures[capture->cur_tex],
				capture->bits, capture->width*4, false);
	} else {
		texture_release_dc(capture->textures[capture->cur_tex]);
	}
}

void dc_capture_capture(struct dc_capture *capture, HWND window)
{
	HDC hdc_target;
	HDC hdc;

	if (capture->capture_cursor) {
		memset(&capture->ci, 0, sizeof(CURSORINFO));
		capture->ci.cbSize = sizeof(CURSORINFO);
		capture->cursor_captured = GetCursorInfo(&capture->ci);
	}

	if (++capture->cur_tex == capture->num_textures)
		capture->cur_tex = 0;

	hdc = dc_capture_get_dc(capture);
	if (!hdc) {
		blog(LOG_WARNING, "[capture_screen] Failed to get "
		                  "texture DC");
		return;
	}

	hdc_target = GetDC(window);

	BitBlt(hdc, 0, 0, capture->width, capture->height,
			hdc_target, capture->x, capture->y, SRCCOPY);

	ReleaseDC(NULL, hdc_target);

	if (capture->cursor_captured)
		draw_cursor(capture, hdc, window);

	dc_capture_release_dc(capture);

	capture->textures_written[capture->cur_tex] = true;
}

static void draw_texture(struct dc_capture *capture, int id, effect_t effect)
{
	texture_t   texture = capture->textures[id];
	technique_t tech    = effect_gettechnique(effect, "Draw");
	eparam_t    image   = effect_getparambyname(effect, "image");
	size_t      passes;

	effect_settexture(image, texture);

	passes = technique_begin(tech);
	for (size_t i = 0; i < passes; i++) {
		if (technique_beginpass(tech, i)) {
			if (capture->compatibility)
				gs_draw_sprite(texture, GS_FLIP_V, 0, 0);
			else
				gs_draw_sprite(texture, 0, 0, 0);

			technique_endpass(tech);
		}
	}
	technique_end(tech);
}

void dc_capture_render(struct dc_capture *capture, effect_t effect)
{
	int last_tex = (capture->cur_tex > 0) ?
		capture->cur_tex-1 : capture->num_textures-1;

	if (!capture->valid)
		return;

	if (capture->textures_written[last_tex])
		draw_texture(capture, last_tex, effect);
}

effect_t create_opaque_effect(void)
{
	effect_t opaque_effect;
	char *effect_file;
	char *error_string = NULL;

	effect_file = obs_find_module_file("win-capture", "opaque.effect");
	if (!effect_file) {
		blog(LOG_ERROR, "[create_opaque_effect] Could not find "
		                "opaque effect file");
		return false;
	}

	gs_entercontext(obs_graphics());

	opaque_effect = gs_create_effect_from_file(effect_file, &error_string);

	if (!opaque_effect) {
		if (error_string)
			blog(LOG_ERROR, "[create_opaque_effect] Failed to "
			                "create opaque effect:\n%s",
			                error_string);
		else
			blog(LOG_ERROR, "[create_opaque_effect] Failed to "
			                "create opaque effect");
	}

	bfree(effect_file);
	bfree(error_string);

	gs_leavecontext();

	return opaque_effect;
}
