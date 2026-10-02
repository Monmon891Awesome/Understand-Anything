/*
 * brz-probe — Direct3D 9 feature probe for Battle Realms-style rendering under Wine.
 *
 * Draws known patterns with the D3D9 features an early-2000s engine like Battle Realms
 * leans on (16-bit and DXT textures, fixed-function texture stages incl. TFACTOR team
 * colours, fixed-function lighting, alpha test/blend, render-to-texture), reads the
 * pixels back, and reports which ones come out wrong — and *how* they are wrong:
 *
 *   PASS        pixel matches the expected colour
 *   BLACK       something was drawn but came out black      (the in-game symptom)
 *   NOT DRAWN   the clear colour is still there              (draw/pipeline dropped)
 *   WRONG       drawn, but a different colour
 *   SKIP        the D3D9 implementation refuses the format/feature (reported, not failed)
 *
 * It also prints which d3d9.dll actually loaded (Wine builtin, DXVK/D9VK, dgVoodoo) and an
 * optional draw-call benchmark, so renderers can be compared on the same Mac.
 *
 * Build:  i686-w64-mingw32-gcc -O2 -std=c11 -Wall -Wextra -o brz-probe.exe brz-probe.c -ld3d9 -static
 * Usage:  wine brz-probe.exe [--swvp] [--on12] [--full] [--bench] [--frames N] [--draws N] [--label NAME] [--timeout SEC]
 *         --timeout: abort with "TIMEOUT during <step>" if no progress for SEC seconds (default 60, 0 = off)
 */

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d9.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PROBE_VERSION "1.0.0"
#define RT_SIZE   256
#define TEX_SIZE  16

/* clear colour that no test expects, so "nothing drawn" is distinguishable from "black" */
#define SENTINEL_R 10
#define SENTINEL_G 20
#define SENTINEL_B 30
#define SENTINEL   D3DCOLOR_XRGB(SENTINEL_R, SENTINEL_G, SENTINEL_B)

typedef IDirect3D9* (WINAPI *PFN_Direct3DCreate9On12)(UINT, void*, UINT);

typedef struct {
  DWORD Enable9On12;
  IUnknown* pD3D12Device;
  IUnknown* ppD3D12Queues[2];
  UINT NumQueues;
  UINT NodeMask;
} BRZ_D3D9ON12_ARGS;

typedef struct { float x, y, z, rhw; D3DCOLOR diffuse; float u, v; } VtxT;
#define FVF_T (D3DFVF_XYZRHW | D3DFVF_DIFFUSE | D3DFVF_TEX1)

typedef struct { float x, y, z, nx, ny, nz; D3DCOLOR diffuse; float u, v; } VtxL;
#define FVF_L (D3DFVF_XYZ | D3DFVF_NORMAL | D3DFVF_DIFFUSE | D3DFVF_TEX1)

typedef struct {
  IDirect3D9*        d3d;
  IDirect3DDevice9*  dev;
  IDirect3DSurface9* backbuffer;
  IDirect3DSurface9* readback;
  HWND               hwnd;
  const char*        mode;
  int pass, fail, skip;
  FILE* out;
} Ctx;

typedef enum { R_PASS, R_BLACK, R_NOT_DRAWN, R_WRONG, R_SKIP, R_ERROR } Result;

/* what the probe is doing right now, for crash/timeout reports */
static volatile const char* g_current = "startup";
static volatile LONG g_progress = 0;
static FILE* volatile g_out = NULL;
static const char* result_name[] = { "PASS", "BLACK", "NOT DRAWN", "WRONG", "SKIP", "ERROR" };

/* ------------------------------------------------------------------------- output */

static void emit(Ctx* c, const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vprintf(fmt, ap);
  va_end(ap);
  if (c && c->out) {
    va_start(ap, fmt);
    vfprintf(c->out, fmt, ap);
    va_end(ap);
    fflush(c->out);                 /* a crash below the probe must not lose the lines so far */
  }
  fflush(stdout);
}

static void pump(void) {
  MSG msg;
  while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
    TranslateMessage(&msg);
    DispatchMessageA(&msg);
  }
}

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l) {
  return DefWindowProcA(h, m, w, l);
}

/* ------------------------------------------------------------------------- identify d3d9.dll */

static int file_contains(const char* path, const char* needle, int ignore_case) {
  FILE* f = fopen(path, "rb");
  if (!f) return 0;
  size_t n = strlen(needle), cap = 1 << 20, keep = n - 1;
  char* buf = malloc(cap + n);
  size_t have = 0, got;
  int found = 0;
  while (!found && (got = fread(buf + have, 1, cap, f)) > 0) {
    size_t len = have + got;
    for (size_t i = 0; i + n <= len && !found; i++)
      found = ignore_case ? _strnicmp(buf + i, needle, n) == 0 : memcmp(buf + i, needle, n) == 0;
    if (len >= keep) { memmove(buf, buf + len - keep, keep); have = keep; } else have = len;
  }
  free(buf);
  fclose(f);
  return found;
}

static void identify_d3d9(Ctx* c) {
  HMODULE mod = GetModuleHandleA("d3d9.dll");
  char path[MAX_PATH] = "?";
  if (mod) GetModuleFileNameA(mod, path, sizeof(path));
  const char* kind = "unknown";
  if (file_contains(path, "dgVoodoo", 0))            kind = "dgVoodoo2 (D3D9 -> D3D11/12)";
  else if (file_contains(path, "dxvk", 1))           kind = "DXVK / D9VK (D3D9 -> Vulkan)";
  else if (file_contains(path, "Wine builtin DLL", 0)) kind = "Wine builtin (WineD3D)";
  else if (file_contains(path, "Wine placeholder DLL", 0)) kind = "Wine placeholder -> builtin (WineD3D)";
  emit(c, "d3d9.dll   %s\n           %s\n", path, kind);

  D3DADAPTER_IDENTIFIER9 id;
  if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(c->d3d, D3DADAPTER_DEFAULT, 0, &id)))
    emit(c, "adapter    %s | driver %s | vendor 0x%04lx device 0x%04lx\n",
         id.Description, id.Driver, (unsigned long)id.VendorId, (unsigned long)id.DeviceId);

  D3DCAPS9 caps;
  if (SUCCEEDED(IDirect3D9_GetDeviceCaps(c->d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, &caps)))
    emit(c, "caps       VS %lu.%lu PS %lu.%lu, %lu texture stages, %lu simultaneous textures, max %lux%lu\n",
         (unsigned long)D3DSHADER_VERSION_MAJOR(caps.VertexShaderVersion), (unsigned long)D3DSHADER_VERSION_MINOR(caps.VertexShaderVersion),
         (unsigned long)D3DSHADER_VERSION_MAJOR(caps.PixelShaderVersion), (unsigned long)D3DSHADER_VERSION_MINOR(caps.PixelShaderVersion),
         (unsigned long)caps.MaxTextureBlendStages, (unsigned long)caps.MaxSimultaneousTextures,
         (unsigned long)caps.MaxTextureWidth, (unsigned long)caps.MaxTextureHeight);
}

/* ------------------------------------------------------------------------- device */

static int create_device(Ctx* c, int swvp, int on12) {
  g_current = on12 ? "Direct3DCreate9On12 / CreateDevice" : swvp ? "CreateDevice (SWVP)" : "CreateDevice (HWVP)";
  c->d3d = NULL;
  if (on12) {
    HMODULE mod = LoadLibraryA("d3d9.dll");
    PFN_Direct3DCreate9On12 fn = mod ? (PFN_Direct3DCreate9On12)(void*)GetProcAddress(mod, "Direct3DCreate9On12") : NULL;
    if (!fn) {
      emit(c, "  SKIP      Direct3DCreate9On12 is not exported by this d3d9.dll (a game with D3D9On12=1 must fall back to Direct3DCreate9)\n");
      c->skip++;
      return -1;
    }
    BRZ_D3D9ON12_ARGS args;
    memset(&args, 0, sizeof(args));
    args.Enable9On12 = TRUE;
    c->d3d = fn(D3D_SDK_VERSION, &args, 1);
  } else {
    c->d3d = Direct3DCreate9(D3D_SDK_VERSION);
  }
  if (!c->d3d) {
    emit(c, "Direct3DCreate9%s failed\n", on12 ? "On12" : "");
    return 0;
  }

  D3DPRESENT_PARAMETERS pp;
  memset(&pp, 0, sizeof(pp));
  pp.Windowed = TRUE;
  pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
  pp.BackBufferWidth = RT_SIZE;
  pp.BackBufferHeight = RT_SIZE;
  pp.BackBufferFormat = D3DFMT_X8R8G8B8;
  pp.BackBufferCount = 1;
  pp.hDeviceWindow = c->hwnd;
  pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;

  DWORD flags = (swvp ? D3DCREATE_SOFTWARE_VERTEXPROCESSING : D3DCREATE_HARDWARE_VERTEXPROCESSING) | D3DCREATE_FPU_PRESERVE;
  HRESULT hr = IDirect3D9_CreateDevice(c->d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, c->hwnd, flags, &pp, &c->dev);
  if (FAILED(hr)) {
    emit(c, "CreateDevice(%s) failed: hr=0x%08lx\n", swvp ? "SWVP" : "HWVP", (unsigned long)hr);
    IDirect3D9_Release(c->d3d);
    c->d3d = NULL;
    return 0;
  }
  IDirect3DDevice9_GetBackBuffer(c->dev, 0, 0, D3DBACKBUFFER_TYPE_MONO, &c->backbuffer);
  IDirect3DDevice9_CreateOffscreenPlainSurface(c->dev, RT_SIZE, RT_SIZE, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &c->readback, NULL);
  return 1;
}

static void destroy_device(Ctx* c) {
  g_current = "device release";
  if (c->readback)   IDirect3DSurface9_Release(c->readback);
  if (c->backbuffer) IDirect3DSurface9_Release(c->backbuffer);
  if (c->dev)        IDirect3DDevice9_Release(c->dev);
  if (c->d3d)        IDirect3D9_Release(c->d3d);
  c->readback = NULL; c->backbuffer = NULL; c->dev = NULL; c->d3d = NULL;
}

static void reset_state(Ctx* c) {
  IDirect3DDevice9* d = c->dev;
  IDirect3DDevice9_SetRenderTarget(d, 0, c->backbuffer);
  IDirect3DDevice9_SetVertexShader(d, NULL);
  IDirect3DDevice9_SetPixelShader(d, NULL);
  IDirect3DDevice9_SetRenderState(d, D3DRS_ZENABLE, D3DZB_FALSE);
  IDirect3DDevice9_SetRenderState(d, D3DRS_CULLMODE, D3DCULL_NONE);
  IDirect3DDevice9_SetRenderState(d, D3DRS_LIGHTING, FALSE);
  IDirect3DDevice9_SetRenderState(d, D3DRS_FOGENABLE, FALSE);
  IDirect3DDevice9_SetRenderState(d, D3DRS_SPECULARENABLE, FALSE);
  IDirect3DDevice9_SetRenderState(d, D3DRS_ALPHATESTENABLE, FALSE);
  IDirect3DDevice9_SetRenderState(d, D3DRS_ALPHABLENDENABLE, FALSE);
  IDirect3DDevice9_SetRenderState(d, D3DRS_COLORVERTEX, TRUE);
  IDirect3DDevice9_SetRenderState(d, D3DRS_DIFFUSEMATERIALSOURCE, D3DMCS_COLOR1);
  IDirect3DDevice9_SetRenderState(d, D3DRS_AMBIENTMATERIALSOURCE, D3DMCS_MATERIAL);
  IDirect3DDevice9_SetRenderState(d, D3DRS_AMBIENT, 0);
  IDirect3DDevice9_SetRenderState(d, D3DRS_TEXTUREFACTOR, 0xffffffff);
  for (DWORD s = 0; s < 8; s++) {
    IDirect3DDevice9_SetTexture(d, s, NULL);
    IDirect3DDevice9_SetTextureStageState(d, s, D3DTSS_COLOROP, s == 0 ? D3DTOP_MODULATE : D3DTOP_DISABLE);
    IDirect3DDevice9_SetTextureStageState(d, s, D3DTSS_ALPHAOP, s == 0 ? D3DTOP_SELECTARG1 : D3DTOP_DISABLE);
    IDirect3DDevice9_SetTextureStageState(d, s, D3DTSS_COLORARG1, D3DTA_TEXTURE);
    IDirect3DDevice9_SetTextureStageState(d, s, D3DTSS_COLORARG2, D3DTA_CURRENT);
    IDirect3DDevice9_SetTextureStageState(d, s, D3DTSS_ALPHAARG1, D3DTA_TEXTURE);
    IDirect3DDevice9_SetTextureStageState(d, s, D3DTSS_ALPHAARG2, D3DTA_CURRENT);
    IDirect3DDevice9_SetTextureStageState(d, s, D3DTSS_TEXCOORDINDEX, s);
    IDirect3DDevice9_SetSamplerState(d, s, D3DSAMP_MINFILTER, D3DTEXF_POINT);
    IDirect3DDevice9_SetSamplerState(d, s, D3DSAMP_MAGFILTER, D3DTEXF_POINT);
    IDirect3DDevice9_SetSamplerState(d, s, D3DSAMP_MIPFILTER, D3DTEXF_NONE);
    IDirect3DDevice9_SetSamplerState(d, s, D3DSAMP_ADDRESSU, D3DTADDRESS_CLAMP);
    IDirect3DDevice9_SetSamplerState(d, s, D3DSAMP_ADDRESSV, D3DTADDRESS_CLAMP);
  }
  /* stage 0 uses DIFFUSE as arg2 so untextured quads show the vertex colour */
  IDirect3DDevice9_SetTextureStageState(d, 0, D3DTSS_COLORARG2, D3DTA_DIFFUSE);
  IDirect3DDevice9_SetTextureStageState(d, 0, D3DTSS_ALPHAARG2, D3DTA_DIFFUSE);

  D3DMATRIX ident;
  memset(&ident, 0, sizeof(ident));
  ident._11 = ident._22 = ident._33 = ident._44 = 1.0f;
  IDirect3DDevice9_SetTransform(d, D3DTS_WORLD, &ident);
  IDirect3DDevice9_SetTransform(d, D3DTS_VIEW, &ident);
  IDirect3DDevice9_SetTransform(d, D3DTS_PROJECTION, &ident);
  IDirect3DDevice9_LightEnable(d, 0, FALSE);
}

/* ------------------------------------------------------------------------- textures */

static int is_dxt(D3DFORMAT f) {
  return f == D3DFMT_DXT1 || f == D3DFMT_DXT3 || f == D3DFMT_DXT5;
}

static WORD to565(int r, int g, int b) { return (WORD)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)); }

/* Fill one mip level with a solid ARGB colour encoded for the texture format. */
static void fill_level(D3DFORMAT f, D3DLOCKED_RECT* lr, UINT w, UINT h, int a, int r, int g, int b) {
  BYTE* row = (BYTE*)lr->pBits;
  if (is_dxt(f)) {
    UINT bw = (w + 3) / 4, bh = (h + 3) / 4;
    for (UINT y = 0; y < bh; y++, row += lr->Pitch) {
      BYTE* p = row;
      for (UINT x = 0; x < bw; x++) {
        if (f == D3DFMT_DXT3) { memset(p, 0xff, 8); p += 8; }
        if (f == D3DFMT_DXT5) { p[0] = 255; p[1] = 255; memset(p + 2, 0, 6); p += 8; }
        WORD c0 = to565(r, g, b);
        p[0] = (BYTE)(c0 & 0xff); p[1] = (BYTE)(c0 >> 8);
        p[2] = p[0]; p[3] = p[1];          /* color1 == color0 so every index decodes to it */
        memset(p + 4, 0, 4);
        p += 8;
      }
    }
    return;
  }
  for (UINT y = 0; y < h; y++, row += lr->Pitch) {
    for (UINT x = 0; x < w; x++) {
      switch (f) {
        case D3DFMT_A8R8G8B8: case D3DFMT_X8R8G8B8:
          ((DWORD*)row)[x] = D3DCOLOR_ARGB(a, r, g, b); break;
        case D3DFMT_R5G6B5:
          ((WORD*)row)[x] = to565(r, g, b); break;
        case D3DFMT_A1R5G5B5: case D3DFMT_X1R5G5B5:
          ((WORD*)row)[x] = (WORD)((a >= 128 ? 0x8000 : 0) | ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)); break;
        case D3DFMT_A4R4G4B4: case D3DFMT_X4R4G4B4:
          ((WORD*)row)[x] = (WORD)(((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)); break;
        case D3DFMT_L8:
          row[x] = (BYTE)r; break;
        case D3DFMT_A8L8:
          ((WORD*)row)[x] = (WORD)((a << 8) | r); break;
        case D3DFMT_A8:
          row[x] = (BYTE)a; break;
        default: break;
      }
    }
  }
}

typedef enum { POOL_MANAGED, POOL_UPDATE, POOL_DYNAMIC } TexPath;

/* Creates a solid-colour texture; returns NULL and sets *why on failure. */
static IDirect3DTexture9* make_texture(Ctx* c, D3DFORMAT f, TexPath path, UINT levels, int a, int r, int g, int b, char* why, size_t whylen) {
  IDirect3DDevice9* d = c->dev;
  IDirect3DTexture9* tex = NULL;
  IDirect3DTexture9* staging = NULL;
  HRESULT hr;

  hr = IDirect3D9_CheckDeviceFormat(c->d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8,
                                    path == POOL_DYNAMIC ? D3DUSAGE_DYNAMIC : 0, D3DRTYPE_TEXTURE, f);
  if (FAILED(hr)) { snprintf(why, whylen, "CheckDeviceFormat says not available (hr=0x%08lx)", (unsigned long)hr); return NULL; }

  if (path == POOL_MANAGED)
    hr = IDirect3DDevice9_CreateTexture(d, TEX_SIZE, TEX_SIZE, levels, 0, f, D3DPOOL_MANAGED, &tex, NULL);
  else if (path == POOL_DYNAMIC)
    hr = IDirect3DDevice9_CreateTexture(d, TEX_SIZE, TEX_SIZE, 1, D3DUSAGE_DYNAMIC, f, D3DPOOL_DEFAULT, &tex, NULL);
  else {
    hr = IDirect3DDevice9_CreateTexture(d, TEX_SIZE, TEX_SIZE, levels, 0, f, D3DPOOL_SYSTEMMEM, &staging, NULL);
    if (SUCCEEDED(hr))
      hr = IDirect3DDevice9_CreateTexture(d, TEX_SIZE, TEX_SIZE, levels, 0, f, D3DPOOL_DEFAULT, &tex, NULL);
  }
  if (FAILED(hr)) {
    snprintf(why, whylen, "CreateTexture failed (hr=0x%08lx)", (unsigned long)hr);
    if (staging) IDirect3DTexture9_Release(staging);
    return NULL;
  }

  IDirect3DTexture9* target = staging ? staging : tex;
  DWORD count = IDirect3DTexture9_GetLevelCount(target);
  for (DWORD lvl = 0; lvl < count; lvl++) {
    D3DSURFACE_DESC desc;
    D3DLOCKED_RECT lr;
    IDirect3DTexture9_GetLevelDesc(target, lvl, &desc);
    hr = IDirect3DTexture9_LockRect(target, lvl, &lr, NULL, path == POOL_DYNAMIC ? D3DLOCK_DISCARD : 0);
    if (FAILED(hr)) {
      snprintf(why, whylen, "LockRect failed (hr=0x%08lx)", (unsigned long)hr);
      IDirect3DTexture9_Release(tex);
      if (staging) IDirect3DTexture9_Release(staging);
      return NULL;
    }
    fill_level(f, &lr, desc.Width, desc.Height, a, r, g, b);
    IDirect3DTexture9_UnlockRect(target, lvl);
  }
  if (staging) {
    hr = IDirect3DDevice9_UpdateTexture(d, (IDirect3DBaseTexture9*)staging, (IDirect3DBaseTexture9*)tex);
    IDirect3DTexture9_Release(staging);
    if (FAILED(hr)) {
      snprintf(why, whylen, "UpdateTexture failed (hr=0x%08lx)", (unsigned long)hr);
      IDirect3DTexture9_Release(tex);
      return NULL;
    }
  }
  return tex;
}

/* ------------------------------------------------------------------------- drawing + readback */

static void quad_t(Ctx* c, D3DCOLOR diffuse) {
  const float lo = RT_SIZE * 0.25f - 0.5f, hi = RT_SIZE * 0.75f - 0.5f;
  VtxT v[4] = {
    { lo, lo, 0.5f, 1.0f, diffuse, 0.0f, 0.0f },
    { hi, lo, 0.5f, 1.0f, diffuse, 1.0f, 0.0f },
    { lo, hi, 0.5f, 1.0f, diffuse, 0.0f, 1.0f },
    { hi, hi, 0.5f, 1.0f, diffuse, 1.0f, 1.0f },
  };
  IDirect3DDevice9_SetFVF(c->dev, FVF_T);
  IDirect3DDevice9_DrawPrimitiveUP(c->dev, D3DPT_TRIANGLESTRIP, 2, v, sizeof(VtxT));
}

static void quad_l(Ctx* c, D3DCOLOR diffuse) {
  VtxL v[4] = {
    { -0.5f,  0.5f, 0.5f, 0, 0, -1, diffuse, 0.0f, 0.0f },
    {  0.5f,  0.5f, 0.5f, 0, 0, -1, diffuse, 1.0f, 0.0f },
    { -0.5f, -0.5f, 0.5f, 0, 0, -1, diffuse, 0.0f, 1.0f },
    {  0.5f, -0.5f, 0.5f, 0, 0, -1, diffuse, 1.0f, 1.0f },
  };
  IDirect3DDevice9_SetFVF(c->dev, FVF_L);
  IDirect3DDevice9_DrawPrimitiveUP(c->dev, D3DPT_TRIANGLESTRIP, 2, v, sizeof(VtxL));
}

static void begin(Ctx* c) {
  InterlockedIncrement(&g_progress);
  IDirect3DDevice9_Clear(c->dev, 0, NULL, D3DCLEAR_TARGET, SENTINEL, 1.0f, 0);
  IDirect3DDevice9_BeginScene(c->dev);
}

/* Ends the scene, reads the centre pixel of the back buffer. */
static int end_and_read(Ctx* c, int* r, int* g, int* b) {
  IDirect3DDevice9_EndScene(c->dev);
  if (FAILED(IDirect3DDevice9_GetRenderTargetData(c->dev, c->backbuffer, c->readback)))
    return 0;
  D3DLOCKED_RECT lr;
  if (FAILED(IDirect3DSurface9_LockRect(c->readback, &lr, NULL, D3DLOCK_READONLY)))
    return 0;
  DWORD px = ((DWORD*)((BYTE*)lr.pBits + (RT_SIZE / 2) * lr.Pitch))[RT_SIZE / 2];
  IDirect3DSurface9_UnlockRect(c->readback);
  *r = (px >> 16) & 0xff; *g = (px >> 8) & 0xff; *b = px & 0xff;
  return 1;
}

static Result classify(int r, int g, int b, int er, int eg, int eb, int tol) {
  if (abs(r - er) <= tol && abs(g - eg) <= tol && abs(b - eb) <= tol) return R_PASS;
  if (r == SENTINEL_R && g == SENTINEL_G && b == SENTINEL_B) return R_NOT_DRAWN;
  if (r < 16 && g < 16 && b < 16) return R_BLACK;
  return R_WRONG;
}

static void report(Ctx* c, const char* name, Result res, int er, int eg, int eb, int r, int g, int b, const char* note) {
  InterlockedIncrement(&g_progress);
  if (res == R_PASS) c->pass++;
  else if (res == R_SKIP) c->skip++;
  else c->fail++;
  if (res == R_SKIP || res == R_ERROR)
    emit(c, "  %-9s %-34s %s\n", result_name[res], name, note ? note : "");
  else
    emit(c, "  %-9s %-34s want %02x%02x%02x got %02x%02x%02x%s%s\n", result_name[res], name,
         er, eg, eb, r, g, b, note ? "  " : "", note ? note : "");
  if (res != R_PASS) {
    /* present the failing frame so a human watching the window sees it too */
    IDirect3DDevice9_Present(c->dev, NULL, NULL, NULL, NULL);
  }
  pump();
}

/* ------------------------------------------------------------------------- tests */

static void finish(Ctx* c, const char* name, int er, int eg, int eb, int tol, const char* note) {
  int r, g, b;
  if (!end_and_read(c, &r, &g, &b)) { report(c, name, R_ERROR, 0, 0, 0, 0, 0, 0, "readback failed"); return; }
  report(c, name, classify(r, g, b, er, eg, eb, tol), er, eg, eb, r, g, b, note);
}

static void test_vertex_color(Ctx* c) {
  g_current = "ff: vertex colour, no texture";
  reset_state(c);
  begin(c);
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLOROP, D3DTOP_SELECTARG2);
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_ALPHAOP, D3DTOP_SELECTARG2);
  quad_t(c, D3DCOLOR_XRGB(255, 128, 0));
  finish(c, "ff: vertex colour, no texture", 255, 128, 0, 8, NULL);
}

static void test_texture(Ctx* c, const char* name, D3DFORMAT f, TexPath path, UINT levels, int a, int r, int g, int b, int er, int eg, int eb, int alpha_replicate) {
  char why[160] = "";
  g_current = name;
  reset_state(c);
  IDirect3DTexture9* tex = make_texture(c, f, path, levels, a, r, g, b, why, sizeof(why));
  if (!tex) { report(c, name, R_SKIP, 0, 0, 0, 0, 0, 0, why); return; }
  begin(c);
  IDirect3DDevice9_SetTexture(c->dev, 0, (IDirect3DBaseTexture9*)tex);
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLORARG1, D3DTA_TEXTURE | (alpha_replicate ? D3DTA_ALPHAREPLICATE : 0));
  quad_t(c, D3DCOLOR_XRGB(255, 255, 255));
  finish(c, name, er, eg, eb, 12, NULL);
  IDirect3DDevice9_SetTexture(c->dev, 0, NULL);
  IDirect3DTexture9_Release(tex);
}

/* Team colour as RTS engines of the era did it: texture alpha marks where TFACTOR shows through. */
static void test_team_color(Ctx* c, const char* name, D3DFORMAT f, int tex_alpha, int er, int eg, int eb) {
  g_current = name;
  char why[160] = "";
  reset_state(c);
  IDirect3DTexture9* tex = make_texture(c, f, POOL_MANAGED, 1, tex_alpha, 0, 255, 0, why, sizeof(why));
  if (!tex) { report(c, name, R_SKIP, 0, 0, 0, 0, 0, 0, why); return; }
  begin(c);
  IDirect3DDevice9_SetTexture(c->dev, 0, (IDirect3DBaseTexture9*)tex);
  IDirect3DDevice9_SetRenderState(c->dev, D3DRS_TEXTUREFACTOR, D3DCOLOR_ARGB(255, 0, 0, 255));
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLOROP, D3DTOP_BLENDTEXTUREALPHA);
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLORARG1, D3DTA_TEXTURE);
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLORARG2, D3DTA_TFACTOR);
  quad_t(c, D3DCOLOR_XRGB(255, 255, 255));
  finish(c, name, er, eg, eb, 20, NULL);
  IDirect3DDevice9_SetTexture(c->dev, 0, NULL);
  IDirect3DTexture9_Release(tex);
}

static void test_tfactor(Ctx* c) {
  g_current = "ff: TFACTOR select";
  reset_state(c);
  begin(c);
  IDirect3DDevice9_SetRenderState(c->dev, D3DRS_TEXTUREFACTOR, D3DCOLOR_ARGB(255, 0, 0, 255));
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLORARG1, D3DTA_TFACTOR);
  quad_t(c, D3DCOLOR_XRGB(255, 255, 255));
  finish(c, "ff: TFACTOR select", 0, 0, 255, 8, NULL);
}

static void test_modulate_two_stages(Ctx* c) {
  g_current = "ff: 2-stage modulate (16-bit)";
  char why[160] = "";
  reset_state(c);
  IDirect3DTexture9* t0 = make_texture(c, D3DFMT_A1R5G5B5, POOL_MANAGED, 1, 255, 0, 255, 0, why, sizeof(why));
  IDirect3DTexture9* t1 = t0 ? make_texture(c, D3DFMT_R5G6B5, POOL_MANAGED, 1, 255, 255, 255, 255, why, sizeof(why)) : NULL;
  if (!t0 || !t1) {
    report(c, "ff: 2-stage modulate (16-bit)", R_SKIP, 0, 0, 0, 0, 0, 0, why);
    if (t0) IDirect3DTexture9_Release(t0);
    return;
  }
  begin(c);
  IDirect3DDevice9_SetTexture(c->dev, 0, (IDirect3DBaseTexture9*)t0);
  IDirect3DDevice9_SetTexture(c->dev, 1, (IDirect3DBaseTexture9*)t1);
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLOROP, D3DTOP_MODULATE);
  IDirect3DDevice9_SetTextureStageState(c->dev, 1, D3DTSS_COLOROP, D3DTOP_MODULATE);
  IDirect3DDevice9_SetTextureStageState(c->dev, 1, D3DTSS_COLORARG1, D3DTA_TEXTURE);
  IDirect3DDevice9_SetTextureStageState(c->dev, 1, D3DTSS_COLORARG2, D3DTA_CURRENT);
  IDirect3DDevice9_SetTextureStageState(c->dev, 1, D3DTSS_ALPHAOP, D3DTOP_SELECTARG1);
  IDirect3DDevice9_SetTextureStageState(c->dev, 1, D3DTSS_ALPHAARG1, D3DTA_CURRENT);
  IDirect3DDevice9_SetTextureStageState(c->dev, 1, D3DTSS_TEXCOORDINDEX, 0);
  quad_t(c, D3DCOLOR_XRGB(255, 255, 255));
  finish(c, "ff: 2-stage modulate (16-bit)", 0, 255, 0, 12, NULL);
  IDirect3DDevice9_SetTexture(c->dev, 0, NULL);
  IDirect3DDevice9_SetTexture(c->dev, 1, NULL);
  IDirect3DTexture9_Release(t0);
  IDirect3DTexture9_Release(t1);
}

static void test_lighting(Ctx* c, const char* name, int use_material, int ambient_only, int er, int eg, int eb) {
  g_current = name;
  reset_state(c);
  IDirect3DDevice9* d = c->dev;
  D3DMATERIAL9 mat;
  memset(&mat, 0, sizeof(mat));
  mat.Diffuse.r = 1.0f; mat.Diffuse.a = 1.0f;                 /* red material */
  mat.Ambient.r = mat.Ambient.g = mat.Ambient.b = mat.Ambient.a = 1.0f;
  IDirect3DDevice9_SetMaterial(d, &mat);

  D3DLIGHT9 light;
  memset(&light, 0, sizeof(light));
  light.Type = D3DLIGHT_DIRECTIONAL;
  light.Diffuse.r = light.Diffuse.g = light.Diffuse.b = light.Diffuse.a = 1.0f;
  light.Direction.z = 1.0f;                                   /* shines along +z onto normals facing -z */
  IDirect3DDevice9_SetLight(d, 0, &light);
  IDirect3DDevice9_LightEnable(d, 0, ambient_only ? FALSE : TRUE);

  IDirect3DDevice9_SetRenderState(d, D3DRS_LIGHTING, TRUE);
  IDirect3DDevice9_SetRenderState(d, D3DRS_AMBIENT, ambient_only ? D3DCOLOR_XRGB(64, 64, 64) : 0);
  IDirect3DDevice9_SetRenderState(d, D3DRS_COLORVERTEX, use_material ? FALSE : TRUE);
  IDirect3DDevice9_SetTextureStageState(d, 0, D3DTSS_COLOROP, D3DTOP_SELECTARG2);
  IDirect3DDevice9_SetTextureStageState(d, 0, D3DTSS_ALPHAOP, D3DTOP_SELECTARG2);
  begin(c);
  quad_l(c, D3DCOLOR_XRGB(0, 255, 0));                        /* green vertex colour */
  finish(c, name, er, eg, eb, 12, NULL);
}

static void test_alpha_test(Ctx* c, const char* name, int tex_alpha, int expect_drawn) {
  g_current = name;
  char why[160] = "";
  reset_state(c);
  IDirect3DTexture9* tex = make_texture(c, D3DFMT_A4R4G4B4, POOL_MANAGED, 1, tex_alpha, 0, 255, 0, why, sizeof(why));
  if (!tex) tex = make_texture(c, D3DFMT_A8R8G8B8, POOL_MANAGED, 1, tex_alpha, 0, 255, 0, why, sizeof(why));
  if (!tex) { report(c, name, R_SKIP, 0, 0, 0, 0, 0, 0, why); return; }
  begin(c);
  IDirect3DDevice9_SetTexture(c->dev, 0, (IDirect3DBaseTexture9*)tex);
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
  IDirect3DDevice9_SetRenderState(c->dev, D3DRS_ALPHATESTENABLE, TRUE);
  IDirect3DDevice9_SetRenderState(c->dev, D3DRS_ALPHAREF, 0x80);
  IDirect3DDevice9_SetRenderState(c->dev, D3DRS_ALPHAFUNC, D3DCMP_GREATER);
  quad_t(c, D3DCOLOR_XRGB(255, 255, 255));
  int r, g, b;
  if (!end_and_read(c, &r, &g, &b)) { report(c, name, R_ERROR, 0, 0, 0, 0, 0, 0, "readback failed"); }
  else if (expect_drawn) report(c, name, classify(r, g, b, 0, 255, 0, 12), 0, 255, 0, r, g, b, NULL);
  else {
    Result res = (r == SENTINEL_R && g == SENTINEL_G && b == SENTINEL_B) ? R_PASS : (r < 16 && g < 16 && b < 16) ? R_BLACK : R_WRONG;
    report(c, name, res, SENTINEL_R, SENTINEL_G, SENTINEL_B, r, g, b, "(expects the quad to be discarded)");
  }
  IDirect3DDevice9_SetTexture(c->dev, 0, NULL);
  IDirect3DTexture9_Release(tex);
}

static void test_alpha_blend(Ctx* c) {
  g_current = "ff: alpha blend";
  char why[160] = "";
  reset_state(c);
  IDirect3DTexture9* tex = make_texture(c, D3DFMT_A8R8G8B8, POOL_MANAGED, 1, 128, 255, 0, 0, why, sizeof(why));
  if (!tex) { report(c, "ff: alpha blend 50% red over clear", R_SKIP, 0, 0, 0, 0, 0, 0, why); return; }
  begin(c);
  IDirect3DDevice9_SetTexture(c->dev, 0, (IDirect3DBaseTexture9*)tex);
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
  IDirect3DDevice9_SetRenderState(c->dev, D3DRS_ALPHABLENDENABLE, TRUE);
  IDirect3DDevice9_SetRenderState(c->dev, D3DRS_SRCBLEND, D3DBLEND_SRCALPHA);
  IDirect3DDevice9_SetRenderState(c->dev, D3DRS_DESTBLEND, D3DBLEND_INVSRCALPHA);
  quad_t(c, D3DCOLOR_XRGB(255, 255, 255));
  /* 128/255 red + 127/255 sentinel */
  finish(c, "ff: alpha blend 50% red over clear", 128 + SENTINEL_R / 2, SENTINEL_G / 2, SENTINEL_B / 2, 10, NULL);
  IDirect3DDevice9_SetTexture(c->dev, 0, NULL);
  IDirect3DTexture9_Release(tex);
}

static void test_render_to_texture(Ctx* c) {
  g_current = "render-to-texture";
  reset_state(c);
  IDirect3DTexture9* rt = NULL;
  IDirect3DSurface9* surf = NULL;
  HRESULT hr = IDirect3DDevice9_CreateTexture(c->dev, 64, 64, 1, D3DUSAGE_RENDERTARGET, D3DFMT_A8R8G8B8, D3DPOOL_DEFAULT, &rt, NULL);
  if (FAILED(hr)) { report(c, "render-to-texture then sample", R_SKIP, 0, 0, 0, 0, 0, 0, "CreateTexture(RENDERTARGET) failed"); return; }
  IDirect3DTexture9_GetSurfaceLevel(rt, 0, &surf);
  IDirect3DDevice9_SetRenderTarget(c->dev, 0, surf);
  IDirect3DDevice9_Clear(c->dev, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(255, 0, 255), 1.0f, 0);
  IDirect3DDevice9_SetRenderTarget(c->dev, 0, c->backbuffer);
  begin(c);
  IDirect3DDevice9_SetTexture(c->dev, 0, (IDirect3DBaseTexture9*)rt);
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
  quad_t(c, D3DCOLOR_XRGB(255, 255, 255));
  finish(c, "render-to-texture then sample", 255, 0, 255, 8, NULL);
  IDirect3DDevice9_SetTexture(c->dev, 0, NULL);
  IDirect3DSurface9_Release(surf);
  IDirect3DTexture9_Release(rt);
}

static void run_suite(Ctx* c) {
  test_vertex_color(c);
  test_tfactor(c);

  /* 32-bit baseline */
  test_texture(c, "tex A8R8G8B8 managed",      D3DFMT_A8R8G8B8, POOL_MANAGED, 1, 255, 0, 255, 0, 0, 255, 0, 0);
  test_texture(c, "tex X8R8G8B8 managed",      D3DFMT_X8R8G8B8, POOL_MANAGED, 1, 255, 0, 255, 0, 0, 255, 0, 0);
  /* the 16-bit formats early-2000s engines use for units/terrain */
  test_texture(c, "tex R5G6B5 managed",        D3DFMT_R5G6B5,   POOL_MANAGED, 1, 255, 0, 255, 0, 0, 255, 0, 0);
  test_texture(c, "tex X1R5G5B5 managed",      D3DFMT_X1R5G5B5, POOL_MANAGED, 1, 255, 0, 255, 0, 0, 255, 0, 0);
  test_texture(c, "tex A1R5G5B5 managed",      D3DFMT_A1R5G5B5, POOL_MANAGED, 1, 255, 0, 255, 0, 0, 255, 0, 0);
  test_texture(c, "tex A4R4G4B4 managed",      D3DFMT_A4R4G4B4, POOL_MANAGED, 1, 255, 0, 255, 0, 0, 255, 0, 0);
  test_texture(c, "tex X4R4G4B4 managed",      D3DFMT_X4R4G4B4, POOL_MANAGED, 1, 255, 0, 255, 0, 0, 255, 0, 0);
  test_texture(c, "tex A1R5G5B5 mipmapped",    D3DFMT_A1R5G5B5, POOL_MANAGED, 0, 255, 0, 255, 0, 0, 255, 0, 0);
  test_texture(c, "tex A4R4G4B4 sysmem->default", D3DFMT_A4R4G4B4, POOL_UPDATE, 1, 255, 0, 255, 0, 0, 255, 0, 0);
  test_texture(c, "tex R5G6B5 dynamic",        D3DFMT_R5G6B5,   POOL_DYNAMIC, 1, 255, 0, 255, 0, 0, 255, 0, 0);
  /* luminance / alpha */
  test_texture(c, "tex L8",                    D3DFMT_L8,       POOL_MANAGED, 1, 255, 200, 0, 0, 200, 200, 200, 0);
  test_texture(c, "tex A8L8",                  D3DFMT_A8L8,     POOL_MANAGED, 1, 255, 200, 0, 0, 200, 200, 200, 0);
  test_texture(c, "tex A8 (alpha replicate)",  D3DFMT_A8,       POOL_MANAGED, 1, 200, 0, 0, 0, 200, 200, 200, 1);
  /* block-compressed */
  test_texture(c, "tex DXT1",                  D3DFMT_DXT1,     POOL_MANAGED, 1, 255, 0, 255, 0, 0, 255, 0, 0);
  test_texture(c, "tex DXT3",                  D3DFMT_DXT3,     POOL_MANAGED, 1, 255, 0, 255, 0, 0, 255, 0, 0);
  test_texture(c, "tex DXT5",                  D3DFMT_DXT5,     POOL_MANAGED, 1, 255, 0, 255, 0, 0, 255, 0, 0);

  /* team colour via texture alpha + TFACTOR */
  test_team_color(c, "team colour A8R8G8B8 alpha=255", D3DFMT_A8R8G8B8, 255, 0, 255, 0);
  test_team_color(c, "team colour A8R8G8B8 alpha=0",   D3DFMT_A8R8G8B8, 0,   0, 0, 255);
  test_team_color(c, "team colour A4R4G4B4 alpha=255", D3DFMT_A4R4G4B4, 255, 0, 255, 0);
  test_team_color(c, "team colour A4R4G4B4 alpha=0",   D3DFMT_A4R4G4B4, 0,   0, 0, 255);
  test_team_color(c, "team colour A1R5G5B5 alpha=0",   D3DFMT_A1R5G5B5, 0,   0, 0, 255);
  test_modulate_two_stages(c);

  /* fixed-function lighting (what HardwareTL=1 asks D3D to do) */
  test_lighting(c, "light: directional, material red", 1, 0, 255, 0, 0);
  test_lighting(c, "light: directional, vertex colour", 0, 0, 0, 255, 0);
  test_lighting(c, "light: ambient only (64 grey)",    1, 1, 64, 64, 64);

  test_alpha_test(c, "alpha test keeps alpha=255", 255, 1);
  test_alpha_test(c, "alpha test drops alpha=0",   0,   0);
  test_alpha_blend(c);
  test_render_to_texture(c);
}

/* ------------------------------------------------------------------------- benchmark */

static double now_ms(void) {
  static LARGE_INTEGER freq;
  LARGE_INTEGER t;
  if (!freq.QuadPart) QueryPerformanceFrequency(&freq);
  QueryPerformanceCounter(&t);
  return (double)t.QuadPart * 1000.0 / (double)freq.QuadPart;
}

/* Many small textured, team-coloured quads with state changes: the "big battle" pattern. */
static void bench(Ctx* c, int frames, int draws) {
  char why[160] = "";
  g_current = "benchmark";
  IDirect3DTexture9* tex[8] = { 0 };
  int ntex = 0;
  reset_state(c);
  for (int i = 0; i < 8; i++) {
    tex[i] = make_texture(c, D3DFMT_A1R5G5B5, POOL_MANAGED, 1, 255, (i * 37) & 255, (i * 91) & 255, (i * 53) & 255, why, sizeof(why));
    if (!tex[i]) tex[i] = make_texture(c, D3DFMT_A8R8G8B8, POOL_MANAGED, 1, 255, (i * 37) & 255, (i * 91) & 255, (i * 53) & 255, why, sizeof(why));
    if (tex[i]) ntex++;
  }
  if (!ntex) { emit(c, "bench: no textures (%s)\n", why); return; }
  emit(c, "phase      benchmark (%d draws/frame)\n", draws);

  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLOROP, D3DTOP_BLENDTEXTUREALPHA);
  IDirect3DDevice9_SetTextureStageState(c->dev, 0, D3DTSS_COLORARG2, D3DTA_TFACTOR);
  IDirect3DDevice9_SetRenderState(c->dev, D3DRS_ALPHATESTENABLE, TRUE);
  IDirect3DDevice9_SetRenderState(c->dev, D3DRS_ALPHAREF, 0x10);
  IDirect3DDevice9_SetRenderState(c->dev, D3DRS_ALPHAFUNC, D3DCMP_GREATER);
  IDirect3DDevice9_SetFVF(c->dev, FVF_T);

  double best = 1e30, total = 0;
  int measured = 0;
  for (int f = 0; f < frames + 10; f++) {
    double t0 = now_ms();
    IDirect3DDevice9_Clear(c->dev, 0, NULL, D3DCLEAR_TARGET, SENTINEL, 1.0f, 0);
    IDirect3DDevice9_BeginScene(c->dev);
    for (int i = 0; i < draws; i++) {
      float x = (float)((i * 13) % (RT_SIZE - 8)), y = (float)((i * 7 + f) % (RT_SIZE - 8));
      VtxT v[4] = {
        { x,     y,     0.5f, 1, 0xffffffff, 0, 0 }, { x + 8, y,     0.5f, 1, 0xffffffff, 1, 0 },
        { x,     y + 8, 0.5f, 1, 0xffffffff, 0, 1 }, { x + 8, y + 8, 0.5f, 1, 0xffffffff, 1, 1 },
      };
      IDirect3DDevice9_SetTexture(c->dev, 0, (IDirect3DBaseTexture9*)tex[i % 8 % (ntex ? ntex : 1)]);
      IDirect3DDevice9_SetRenderState(c->dev, D3DRS_TEXTUREFACTOR, D3DCOLOR_XRGB((i * 5) & 255, (i * 11) & 255, (i * 17) & 255));
      IDirect3DDevice9_DrawPrimitiveUP(c->dev, D3DPT_TRIANGLESTRIP, 2, v, sizeof(VtxT));
    }
    IDirect3DDevice9_EndScene(c->dev);
    IDirect3DDevice9_Present(c->dev, NULL, NULL, NULL, NULL);
    pump();
    InterlockedIncrement(&g_progress);
    double dt = now_ms() - t0;
    if (f >= 10) { total += dt; measured++; if (dt < best) best = dt; }   /* first 10 frames = warm-up (shader compiles) */
  }
  int r, g, b;
  IDirect3DDevice9_BeginScene(c->dev);
  end_and_read(c, &r, &g, &b);                                           /* drain the GPU queue */
  double avg = total / (measured ? measured : 1);
  emit(c, "bench      %d draws/frame x %d frames: avg %.2f ms (%.0f fps), best %.2f ms, %.0f draws/s\n",
       draws, measured, avg, 1000.0 / avg, best, draws * 1000.0 / avg);
  for (int i = 0; i < 8; i++) if (tex[i]) IDirect3DTexture9_Release(tex[i]);
}

/* ------------------------------------------------------------------------- crash / hang handling */

static void final_line(const char* what, unsigned long code) {
  char line[512];
  snprintf(line, sizeof(line), "\n%s during: %s (code 0x%08lx)\n"
           "summary    aborted — the d3d9 implementation crashed or hung in the step above\n",
           what, (const char*)g_current, code);
  fputs(line, stdout);
  fflush(stdout);
  if (g_out) { fputs(line, g_out); fflush(g_out); }
}

/* C++ layers (DXVK) abort() via std::terminate when they cannot start, e.g. no usable Vulkan device */
static void abort_handler(int sig) {
  (void)sig;
  static const char hint[] =
    "hint       an abort at CreateDevice usually means the D3D9 layer found no usable GPU driver\n"
    "           (for DXVK 3.x on a Mac: MoltenVK older than 1.3.0 lacks VK_KHR_load_store_op_none)\n";
  final_line("ABORT", 3);
  fputs(hint, stdout);
  fflush(stdout);
  if (g_out) { fputs(hint, g_out); fflush(g_out); }
  _exit(202);
}

static LONG WINAPI crash_filter(EXCEPTION_POINTERS* info) {
  final_line("CRASH", info && info->ExceptionRecord ? (unsigned long)info->ExceptionRecord->ExceptionCode : 0);
  ExitProcess(200);
  return EXCEPTION_EXECUTE_HANDLER;
}

static DWORD WINAPI watchdog(LPVOID param) {
  DWORD limit_ms = (DWORD)(UINT_PTR)param;
  LONG last = -1;
  DWORD idle = 0;
  for (;;) {
    Sleep(1000);
    LONG now = g_progress;
    idle = (now == last) ? idle + 1000 : 0;
    last = now;
    if (idle >= limit_ms) {
      final_line("TIMEOUT", (unsigned long)limit_ms);
      ExitProcess(201);
    }
  }
  return 0;
}

/* ------------------------------------------------------------------------- main */

static void run_mode(Ctx* c, const char* mode, int swvp, int on12, int do_bench, int frames, int draws, int print_ident) {
  c->mode = mode;
  emit(c, "\n== %s ==\n", mode);
  int created = create_device(c, swvp, on12);
  if (created < 0) return;                      /* feature absent: already reported as SKIP */
  if (!created) { c->fail++; return; }
  if (print_ident) identify_d3d9(c);
  run_suite(c);
  if (do_bench) bench(c, frames, draws);
  destroy_device(c);
}

int main(int argc, char** argv) {
  int swvp = 0, on12 = 0, full = 0, do_bench = 0, frames = 120, draws = 2000, timeout_s = 60;
  const char* label = "run";
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--swvp")) swvp = 1;
    else if (!strcmp(argv[i], "--on12")) on12 = 1;
    else if (!strcmp(argv[i], "--full")) full = 1;
    else if (!strcmp(argv[i], "--bench")) do_bench = 1;
    else if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--draws") && i + 1 < argc) draws = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--label") && i + 1 < argc) label = argv[++i];
    else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) timeout_s = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
      printf("brz-probe %s\nusage: brz-probe.exe [--swvp] [--on12] [--full] [--bench] [--frames N] [--draws N] [--label NAME] [--timeout SEC]\n", PROBE_VERSION);
      return 0;
    }
  }

  Ctx c;
  memset(&c, 0, sizeof(c));
  char outname[MAX_PATH];
  snprintf(outname, sizeof(outname), "brz-probe-%s.txt", label);
  c.out = fopen(outname, "w");
  g_out = c.out;
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  SetUnhandledExceptionFilter(crash_filter);
  signal(SIGABRT, abort_handler);
  if (timeout_s > 0)
    CloseHandle(CreateThread(NULL, 0, watchdog, (LPVOID)(UINT_PTR)(timeout_s * 1000), 0, NULL));

  WNDCLASSA wc;
  memset(&wc, 0, sizeof(wc));
  wc.lpfnWndProc = wndproc;
  wc.hInstance = GetModuleHandleA(NULL);
  wc.lpszClassName = "brz_probe";
  wc.hCursor = LoadCursor(NULL, IDC_ARROW);
  RegisterClassA(&wc);
  RECT rc = { 0, 0, RT_SIZE, RT_SIZE };
  AdjustWindowRect(&rc, WS_OVERLAPPEDWINDOW, FALSE);
  c.hwnd = CreateWindowA("brz_probe", "brz-probe", WS_OVERLAPPEDWINDOW, 40, 40,
                         rc.right - rc.left, rc.bottom - rc.top, NULL, NULL, wc.hInstance, NULL);
  ShowWindow(c.hwnd, SW_SHOWNOACTIVATE);
  pump();

  emit(&c, "brz-probe %s (label: %s)\n", PROBE_VERSION, label);
  if (full) {
    run_mode(&c, "HWVP device (like HardwareTL=1)", 0, 0, do_bench, frames, draws, 1);
    run_mode(&c, "SWVP device (like HardwareTL=0)", 1, 0, 0, frames, draws, 0);
    run_mode(&c, "Direct3DCreate9On12 (like D3D9On12=1)", 0, 1, 0, frames, draws, 0);
  } else {
    run_mode(&c, swvp ? "SWVP device" : on12 ? "Direct3DCreate9On12 device" : "HWVP device",
             swvp, on12, do_bench, frames, draws, 1);
  }

  emit(&c, "\nsummary    %d passed, %d failed, %d skipped  -> %s\n", c.pass, c.fail, c.skip, outname);
  if (c.out) fclose(c.out);
  DestroyWindow(c.hwnd);
  return c.fail > 255 ? 255 : c.fail;
}
