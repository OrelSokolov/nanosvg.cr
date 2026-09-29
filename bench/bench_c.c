// C benchmark: NanoSVG parse + rasterize, timed separately.
// Usage: ./bench_c <file.svg> [file2.svg ...]
// Build: gcc -O2 -o bench_c bench_c.c -lm

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define NANOSVG_IMPLEMENTATION
#include "../../nanosvg/src/nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "../../nanosvg/src/nanosvgrast.h"

static double now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static char *read_file(const char *path, long *out_len) {
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	long len = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *buf = malloc(len + 1);
	if (fread(buf, 1, len, f) != (size_t)len) { fclose(f); free(buf); return NULL; }
	fclose(f);
	buf[len] = '\0';
	*out_len = len;
	return buf;
}

int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr, "usage: %s <file.svg> [...]\n", argv[0]); return 1; }
	const int N_PARSE = 50, N_RAST = 20;

	for (int a = 1; a < argc; a++) {
		long len;
		char *data = read_file(argv[a], &len);
		if (!data) { fprintf(stderr, "cannot read %s\n", argv[a]); continue; }

		NSVGimage *image = NULL;
		double parse_min = 1e9, parse_sum = 0;

		// --- parse benchmark (nsvgParse mutates the buffer -> fresh copy each iter) ---
		for (int i = 0; i < N_PARSE; i++) {
			char *copy = malloc(len + 1);
			memcpy(copy, data, len + 1);
			double t0 = now_ms();
			image = nsvgParse(copy, "px", 96.0f);
			double t1 = now_ms();
			double dt = t1 - t0;
			if (dt < parse_min) parse_min = dt;
			parse_sum += dt;
			free(copy);
		}
		printf("%-12s parse:  avg %8.3f ms  min %8.3f ms\n",
		       argv[a], parse_sum / N_PARSE, parse_min);

		int iw = (int)image->width, ih = (int)image->height;
		NSVGrasterizer *rast = nsvgCreateRasterizer();

		// --- rasterize benchmark at icon widths 128/512/1024 ---
		const int widths[] = {128, 512, 1024};
		for (size_t widx = 0; widx < 3; widx++) {
			float scale = (float)widths[widx] / (float)iw;
			int w = (int)(iw * scale + 0.5f);
			int h = (int)(ih * scale + 0.5f);
			if (w < 1) w = 1;
			if (h < 1) h = 1;
			unsigned char *pix = malloc((size_t)w * h * 4);
			double rast_min = 1e9, rast_sum = 0;
			for (int i = 0; i < N_RAST; i++) {
				double t0 = now_ms();
				nsvgRasterize(rast, image, 0.0f, 0.0f, scale, pix, w, h, w * 4);
				double t1 = now_ms();
				double dt = t1 - t0;
				if (dt < rast_min) rast_min = dt;
				rast_sum += dt;
			}
			printf("%-12s raster w=%4d (%dx%d): avg %8.3f ms  min %8.3f ms\n",
			       argv[a], widths[widx], w, h, rast_sum / N_RAST, rast_min);
			free(pix);
		}

		nsvgDeleteRasterizer(rast);
		nsvgDelete(image);
		free(data);
	}
	return 0;
}
