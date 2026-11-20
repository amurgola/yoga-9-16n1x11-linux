/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Lenovo Yoga 9 2-in-1 16N1X11 (83N7) front camera, a port of ikegam/surface-ultra-camera
 * (Surface Laptop Ultra, same NVIDIA N1x / MediaTek ISP8 seninf -> camsv):
 *   front: OV08X40, CSI port 0, 4 lanes, 3840x2400 RAW10 (as Windows runs it)
 *   IR:    VD55G0 on CSI port 2, 1 lane, 640x480 RAW10 (module parameter ir=1)
 * Front path: outmux1 -> camsv_b.
 */
#ifndef SUCAM_DRV_H
#define SUCAM_DRV_H

#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/kthread.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/workqueue.h>
#include <media/media-device.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-subdev.h>
#include <media/videobuf2-v4l2.h>

/*
 * Windows streams the OV08X40 at 3840x2400 (outmux tag size 0x095f0eff, camsv grab
 * 0x0f00/0x0960 in the ccusnoop dump) and camsv takes the whole frame. Unpacked
 * RAW10 is 3840 * 2 * 2400 = 18432000 bytes per buffer, far above the 4 MiB that
 * plain contiguous allocation gives, so the kernel needs a CMA area (cma=96M).
 */
#define SUCAM_W		3840
#define SUCAM_H		2400
#define SUCAM_FPS	30
/* the sensor mode Windows programs (ov08x40_win.h): 3840x2400 output */
#define SUCAM_SENSOR_W	3840
#define SUCAM_SENSOR_H	2400

/* camsv_b interrupts in ISP1 _CRS: 0x20A = done/err, 0x20D = SOF (tag n at bit 2+4n) */
#define SUCAM_SOF_GSI	0x20D

/* camsv_b FORMAT_TAG2 (+0x594): pixel depth in the low field (0 RAW8, 1 RAW10),
 * bit 6 = unpacked into 16-bit words (docs/camsv-output-format.md) */
#define SUCAM_SV_RAW8		0x00
#define SUCAM_SV_RAW10		0x01
#define SUCAM_SV_UNPACKED	BIT(6)

/*
 * OV08X40 as Windows programs it: HTS 0x0280, VTS 0x1388 (5000 lines). The frame
 * rate has not been measured yet; SUCAM_FPS and the pixel rate below are the
 * bookkeeping libcamera needs (frame = (W + HBLANK) * (H + VBLANK) / PIXEL_RATE)
 * and must be corrected once frames flow (the Surface port did the same).
 */
#define SUCAM_VTS		5000
#define SUCAM_VTS_MAX		0x7fff
#define SUCAM_EXP_MIN		4
#define SUCAM_EXP_MAX		(SUCAM_VTS - 8)
#define SUCAM_LLP		5120		/* must exceed SUCAM_W; 8 x HTS */
#define SUCAM_PIXEL_RATE	((u64)SUCAM_LLP * SUCAM_VTS * SUCAM_FPS)
#define SUCAM_EXP_DEF		0x410		/* Windows' last value at stream start */
/* analog gain: 0x3508/09 holds ctrl << 1 (in-tree ov08x40); Windows writes 0x0800 */
#define SUCAM_AGAIN_MIN		0x80
#define SUCAM_AGAIN_MAX		0x7c0
#define SUCAM_AGAIN_DEF		0x400
/* digital gain in 1/1024 steps over 0x350a-c (in-tree ov08x40); Windows: 1x */
#define SUCAM_DGAIN_MIN		0x400
#define SUCAM_DGAIN_MAX		0xfff
#define SUCAM_DGAIN_DEF		0x400

/*
 * IR camera (VD55G0): 640x480 mono RAW10 out of the sensor, Windows' crop at
 * (2, 62) of 644x604. 640 bytes of 8-bit grey per line are 16-byte aligned,
 * so camsv grabs the full width.
 */
#define SUCAM_IR_GRAB_X		0
#define SUCAM_IR_W		640
#define SUCAM_IR_H		480
/* lines: 30 fps at 1500 Mbps (measured: 4433 lines gave 37.2 fps, so the pixel
 * clock is rate / 8 = 187.5 MHz; line length 1128) */
#define SUCAM_IR_FRAME_LENGTH	5541
/*
 * The IR image is lit by the illuminator, which the sensor strobes for the
 * exposure time; its driver stops the pulse somewhere between 2800 and 3300
 * lines (black frames). The sensor's own AE runs the exposure up to the frame
 * length, so default to a fixed exposure in the lit range.
 */
/* Yoga: Windows' own exposure loop went up to 3989 lines (7.5 us each) and gain
 * codes 1..24; default to a quarter-frame pulse. */
#define SUCAM_IR_EXP_MAX	5000
#define SUCAM_IR_EXP_DEF	1000
#define SUCAM_IR_AGAIN_MAX	28
#define SUCAM_IR_AGAIN_DEF	16
#define SUCAM_IR_SENSOR_W	644
#define SUCAM_IR_SENSOR_H	604
/* frame timing for libcamera, as for the front camera (lines are what count) */
#define SUCAM_IR_LLP		1128
#define SUCAM_IR_PIXEL_RATE	((u64)SUCAM_IR_LLP * SUCAM_IR_FRAME_LENGTH * SUCAM_FPS)

struct sucam_fmt {
	u32 fourcc, stride, sv_fmt;
	const char *desc;
};

struct sucam_cfg {
	bool ir;
	const char *card;		/* V4L2 card name */
	const char *input;
	u32 width, height;
	const struct sucam_fmt *fmts;	/* fmts[0] is the default */
	unsigned int nfmts;
	/* media graph: sensor subdev */
	const char *sensor;		/* driver name of the sensor (libcamera's model) */
	u32 mbus;
	struct v4l2_rect native, crop;	/* sensor array and the part camsv grabs */
};

extern const struct sucam_cfg sucam_front_cfg, sucam_ir_cfg;

enum { SUCAM_GPIO_CAMPOWER, SUCAM_GPIO_AVDD, SUCAM_GPIO_MCLK, SUCAM_GPIO_RESET,
       SUCAM_GPIO_PLED, SUCAM_GPIO_NUM };

struct sucam_buf {
	struct vb2_v4l2_buffer vb;
	struct list_head list;
};

struct sucam {
	struct device *dev;
	const struct sucam_cfg *cfg;
	const struct sucam_fmt *fmt;	/* current capture format */
	struct v4l2_device v4l2_dev;
	struct video_device vdev;
	struct vb2_queue queue;
	struct v4l2_ctrl_handler ctrls;
	struct v4l2_ctrl *exposure, *again, *dgain;
	u32 vts;			/* front sensor frame length, lines */

	/* front camera media graph: sensor -> seninf -> video node */
	struct media_device mdev;
	struct media_pad vpad;
	struct v4l2_subdev sensor_sd, seninf_sd;
	struct media_pad sensor_pad, seninf_pads[2];
	struct mutex lock;		/* vdev / vb2 / hw state */

	/* hw */
	void __iomem *hfrp, *ccu, *sv;
	struct i2c_client *sensor;
	struct device *sensor_dev;
	struct gpio_desc *gpio[SUCAM_GPIO_NUM];
	bool powered, streaming;

	/* buffer flow (camsv FBC, driven by the camsv_b SOF interrupt) */
	spinlock_t qlock;
	struct list_head queued;	/* waiting to be armed */
	struct sucam_buf *pending;	/* in the outer WDMA addr, latched at next SOF */
	struct sucam_buf *writing;	/* latched by the last SOF, being written */
	int irq;			/* SOF interrupt, < 0 if unavailable */
	bool irq_on;			/* requested for the current stream */
	struct task_struct *poll;	/* fallback when there is no interrupt */
	struct delayed_work watchdog;	/* logs hardware state while frames stall */
	u32 watch_seq;
	struct work_struct recover;	/* restarts a stream that delivers no frames */
	u8 stalled, recoveries;
	u8 last_wcnt;
	u32 sequence;
	u32 dropped;		/* frames lost at SOF (buffer requeued) */
};

int sucam_hw_init(struct sucam *cam);
void sucam_hw_exit(struct sucam *cam);
int sucam_hw_start(struct sucam *cam, dma_addr_t first);
void sucam_hw_stop(struct sucam *cam);
void sucam_hw_arm(struct sucam *cam, dma_addr_t addr);
u8 sucam_hw_wcnt(struct sucam *cam);
void sucam_hw_power_lost(void);
bool sucam_hw_sof(struct sucam *cam);
void sucam_hw_diag(struct sucam *cam);
void sucam_hw_stream_result(struct sucam *cam, u32 frames);
int sucam_sensor_set(struct sucam *cam, u32 id, s32 val);

/* sucam_mc.c */
int sucam_mc_init(struct sucam *cam);
int sucam_mc_register(struct sucam *cam);
void sucam_mc_unregister(struct sucam *cam);

/* sucam_vd55g0.c */
extern const s64 sucam_ir_ev_bias[13];		/* milli-EV, -3 .. +3 in half steps */
extern const u8 sucam_ir_ae_target[13];		/* matching AE target percentages */
int sucam_vd_power(struct sucam *cam, bool on);
int sucam_vd_stream(struct sucam *cam, bool on);
int sucam_vd_set(struct sucam *cam, u32 id, s32 val);

#endif
