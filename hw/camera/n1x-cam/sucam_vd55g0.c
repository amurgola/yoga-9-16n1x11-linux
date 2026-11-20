// SPDX-License-Identifier: GPL-2.0
/*
 * Lenovo Yoga 9 2-in-1 16N1X11 (83N7) IR camera: ST VD55G0 (mono, global shutter, 644x604)
 * on ACPI CAMI (I2C4 @0x10), lit by two IR LEDs behind a TI LM3644 (I2C4 @0x63) that the
 * sensor strobes for the exposure time.
 *
 * Register map and power-up order: STMicroelectronics' vd55g0 driver (wait READY_TO_BOOT,
 * firmware patch, PATCH_SETUP, BOOT, SW_STBY). Values: what the Windows driver writes on
 * this machine (../vd55g0-session3-sequence.txt): 24 MHz clock, 1500 Mbps on one lane,
 * line length 1128, 640x480 RAW10 at (2, 62), strobe on sensor GPIO0. Windows runs its own
 * exposure loop from the host; here the exposure is manual (controls) or the sensor's AE.
 */
#include <linux/delay.h>
#include <linux/firmware.h>
#include <linux/i2c.h>
#include <linux/iopoll.h>
#include <linux/module.h>
#include <linux/unaligned.h>
#include "sucam.h"

/*
 * The sensor needs a firmware patch written to 0x2000 before it boots. It is ST's
 * property and ships inside the Windows sensor driver, so it is not part of this
 * source: tools/extract-vd55g0-patch.py copies it out of your own Windows installation
 * into /lib/firmware.
 */
#define VD_PATCH_FW		"nvidia/n1x/vd55g0-patch.bin"
#define VD_PATCH_MAX		4096
MODULE_FIRMWARE(VD_PATCH_FW);

#define VD_MODEL_ID		0x0000	/* 16 bit: 0x4730 */
#define VD_REVISION		0x0004
#define VD_FWPATCH_REVISION	0x0022
#define VD_FSM			0x002c
#define  FSM_READY_TO_BOOT	1
#define  FSM_SW_STBY		2
#define  FSM_STREAMING		3
#define VD_BOOT			0x0200
#define  BOOT_BOOT		1
#define  BOOT_PATCH_SETUP	2
#define VD_STBY			0x0201	/* 1 = start streaming */
#define VD_STREAMING		0x0202	/* 1 = stop streaming */
#define VD_EXT_CLOCK		0x0220	/* 32 bit, Hz */
#define VD_CLK_PLL_MIPI		0x0224	/* 32 bit, bit/s */
#define VD_LINE_LENGTH		0x0300
#define VD_FORMAT_CTRL		0x030a	/* bits per pixel */
#define VD_OIF_IMG_CTRL		0x030f	/* CSI-2 data type */
#define VD_AE_TARGET_PERCENTAGE	0x0440
#define VD_EXP_MODE		0x044c
#define  EXP_AUTO		0
#define  EXP_MANUAL		2
#define VD_MANUAL_AGAIN		0x044d
#define VD_MANUAL_EXPOSURE	0x044e	/* 16 bit, lines */
#define VD_FRAME_LENGTH		0x0458	/* 16 bit, lines */
#define VD_GPIO0_CTRL		0x0467
#define  GPIO_IDLE		0x05	/* what Windows parks all four GPIOs at */
#define  GPIO_STROBE		0x02
#define VD_PATCH		0x2000

#define VD_XCLK			24000000
#define VD_LLP			1128

/* LM3644 IR LED driver */
#define LM_ADDR			0x63
#define LM_ENABLE		0x01
#define  LM_ENABLE_IR_STROBE	0xa7	/* TX + strobe pin, IR mode, LED1 + LED2 (Windows) */
#define LM_LED1_FLASH		0x03
#define LM_LED2_FLASH		0x04
#define LM_FLAGS1		0x0a
#define LM_FLAGS2		0x0b
#define LM_DEVICE_ID		0x0c

/* MIPI rate; Windows uses 1500. 1086 is what the Surface's receiver tables were tuned at. */
static unsigned int ir_mbps = 1500;
module_param(ir_mbps, uint, 0644);
/* LM3644 LED current codes as Windows sets them (about 300 mA each); lower = dimmer */
static unsigned int ir_led1 = 0x19, ir_led2 = 0x18;
module_param(ir_led1, uint, 0644);
module_param(ir_led2, uint, 0644);

static unsigned int ir_strobe_gpio;	/* sensor GPIO that strobes the LEDs (Windows: 0) */
module_param(ir_strobe_gpio, uint, 0644);
static int ir_gpio2 = -1;		/* override for GPIO2's mode (Windows: 0x15) */
module_param(ir_gpio2, int, 0644);
static int ir_gpio0 = -1;		/* override for GPIO0's mode (Windows: 0x02 strobe) */
module_param(ir_gpio0, int, 0644);
/*
 * LED drive. Windows arms the LM3644 for strobed IR pulses (enable 0xa7), but on this
 * machine no sensor GPIO mode tried (strobe on GPIO0..3, static high/low on GPIO0) made
 * the LEDs fire: the strobe source is still unknown. Torch mode (continuous, I2C only)
 * does light the scene, so it is the default: current code 1..0x3f, about 1.4 mA per
 * code and LED. ir_torch=0 selects Windows' strobed setting.
 */
static unsigned int ir_torch = 48;
module_param(ir_torch, uint, 0644);

/*
 * Auto exposure tuning. With the whole-image window and Windows' 30 % target, a dark
 * room behind the user made the sensor overexpose the face to blank white (2026-11-19
 * evening, Howdy timed out). ir_ae_roi = x0,x1,y0,y1 (sensor coordinates as in the ROI
 * registers) replaces the metering window when x1 is not 0.
 */
static unsigned int ir_ae_target = 14;	/* Windows: 30 */
module_param(ir_ae_target, uint, 0644);
static unsigned int ir_ae_roi[4];
module_param_array(ir_ae_roi, uint, NULL, 0644);

struct vdreg { u16 reg; u8 val; };
/* Windows' writes between boot and stream start, minus clocks/exposure (set below) */
static const struct vdreg vd55g0_windows[] = {
	{ 0x0416, 0x40 },				/* dark calibration pedestal */
	{ 0x0440, 0x1e }, { 0x0441, 0x00 },		/* AE target 30 % */
	{ 0x0467, 0x05 }, { 0x0468, 0x05 }, { 0x0469, 0x05 }, { 0x046a, 0x05 },
	{ 0x046d, 0x00 },
	{ 0x045a, 0x3e }, { 0x045b, 0x00 },		/* Y_START 62 */
	{ 0x045c, 0x1d }, { 0x045d, 0x02 },		/* Y_END 541 */
	{ 0x045e, 0x02 }, { 0x045f, 0x00 },		/* ROI x 2 .. 641 */
	{ 0x0460, 0x81 }, { 0x0461, 0x02 },
	{ 0x0462, 0x00 }, { 0x0463, 0x00 },		/* ROI y 0 .. 479 */
	{ 0x0464, 0xdf }, { 0x0465, 0x01 },
	{ 0x0467, 0x02 },				/* GPIO0: strobe -> LM3644 */
	/*
	 * AE ROI as Windows sets it: the whole image (2..641 x 0..479). The module
	 * parameters ir_ae_roi / ir_ae_target below override it.
	 */
	{ 0x0436, 0x02 }, { 0x0437, 0x00 },
	{ 0x0438, 0x00 }, { 0x0439, 0x00 },
	{ 0x043a, 0x81 }, { 0x043b, 0x02 },
	{ 0x043c, 0xdf }, { 0x043d, 0x01 },
	{ 0x0469, 0x15 },				/* GPIO2, as Windows */
};

static int vd_write(struct sucam *cam, u16 reg, const void *val, int len)
{
	u8 b[2 + 16];
	int ret;

	b[0] = reg >> 8;
	b[1] = reg & 0xff;
	memcpy(b + 2, val, len);
	ret = i2c_master_send(cam->sensor, b, len + 2);
	return ret == len + 2 ? 0 : (ret < 0 ? ret : -EIO);
}

static int vd_write8(struct sucam *cam, u16 reg, u8 val)
{
	return vd_write(cam, reg, &val, 1);
}

static int vd_write16(struct sucam *cam, u16 reg, u16 val)
{
	u8 b[2];

	put_unaligned_le16(val, b);
	return vd_write(cam, reg, b, 2);
}

static int vd_write32(struct sucam *cam, u16 reg, u32 val)
{
	u8 b[4];

	put_unaligned_le32(val, b);
	return vd_write(cam, reg, b, 4);
}

static int vd_read(struct sucam *cam, u16 reg, u8 *val, int len)
{
	u8 a[2] = { reg >> 8, reg & 0xff };
	struct i2c_msg m[2] = {
		{ .addr = cam->sensor->addr, .len = 2, .buf = a },
		{ .addr = cam->sensor->addr, .flags = I2C_M_RD, .len = len, .buf = val },
	};
	int ret = i2c_transfer(cam->sensor->adapter, m, 2);

	return ret == 2 ? 0 : (ret < 0 ? ret : -EIO);
}

static int vd_read8(struct sucam *cam, u16 reg)
{
	u8 v;

	return vd_read(cam, reg, &v, 1) ?: v;
}

static int vd_wait(struct sucam *cam, u16 reg, u8 want)
{
	int v;

	return read_poll_timeout(vd_read8, v, v == want, 2000, 500000, false, cam, reg);
}

/* ---- LM3644 on the same bus ---- */
static int lm_write(struct sucam *cam, u8 reg, u8 val)
{
	u8 b[2] = { reg, val };
	struct i2c_msg m = { .addr = LM_ADDR, .len = 2, .buf = b };
	int ret = i2c_transfer(cam->sensor->adapter, &m, 1);

	return ret == 1 ? 0 : (ret < 0 ? ret : -EIO);
}

static int lm_read(struct sucam *cam, u8 reg)
{
	u8 v = 0;
	struct i2c_msg m[2] = {
		{ .addr = LM_ADDR, .len = 1, .buf = &reg },
		{ .addr = LM_ADDR, .flags = I2C_M_RD, .len = 1, .buf = &v },
	};
	int ret = i2c_transfer(cam->sensor->adapter, m, 2);

	return ret == 2 ? v : (ret < 0 ? ret : -EIO);
}

static int lm_led(struct sucam *cam, bool on)
{
	int id, f1, f2, ret;

	if (!on)
		return lm_write(cam, LM_ENABLE, 0);
	id = lm_read(cam, LM_DEVICE_ID);
	f1 = lm_read(cam, LM_FLAGS1);	/* reading clears latched faults */
	f2 = lm_read(cam, LM_FLAGS2);
	if (id < 0 || (f1 | f2))
		dev_info(cam->dev, "IR LED driver: id %d flags %02x %02x\n", id, f1, f2);
	if (id < 0)
		return id;
	if (ir_torch) {		/* about 1.4 mA per code and LED */
		ret = lm_write(cam, 0x05, min(ir_torch, 0x3fu));
		ret = ret ?: lm_write(cam, 0x06, min(ir_torch, 0x3fu));
		return ret ?: lm_write(cam, LM_ENABLE, 0x0b);	/* torch mode, LED1 + LED2 */
	}
	ret = lm_write(cam, LM_LED1_FLASH, min(ir_led1, 0x19u));
	ret = ret ?: lm_write(cam, LM_LED2_FLASH, min(ir_led2, 0x19u));
	return ret ?: lm_write(cam, LM_ENABLE, LM_ENABLE_IR_STROBE);
}

/* exposure bias: AE target 30 % * 2^EV */
const s64 sucam_ir_ev_bias[13] = {
	-3000, -2500, -2000, -1500, -1000, -500, 0, 500, 1000, 1500, 2000, 2500, 3000,
};
const u8 sucam_ir_ae_target[13] = { 4, 5, 8, 11, 15, 21, 30, 42, 60, 85, 100, 100, 100 };

int sucam_vd_set(struct sucam *cam, u32 id, s32 val)
{
	if (!cam->powered)
		return 0;	/* applied at next stream start */
	switch (id) {
	case V4L2_CID_EXPOSURE_AUTO:
		return vd_write8(cam, VD_EXP_MODE, val == V4L2_EXPOSURE_AUTO ? EXP_AUTO : EXP_MANUAL);
	case V4L2_CID_AUTO_EXPOSURE_BIAS:
		return vd_write8(cam, VD_AE_TARGET_PERCENTAGE,
				 clamp(sucam_ir_ae_target[val] * ir_ae_target / 30, 1u, 100u));
	case V4L2_CID_EXPOSURE:		/* lines, used in manual mode */
		return vd_write16(cam, VD_MANUAL_EXPOSURE, val);
	case V4L2_CID_ANALOGUE_GAIN:
		return vd_write8(cam, VD_MANUAL_AGAIN, val);
	case V4L2_CID_FLASH_LED_MODE:	/* IR LEDs: strobed with the exposure, or off */
		return lm_led(cam, val != V4L2_FLASH_LED_MODE_NONE);
	case V4L2_CID_HBLANK:		/* read-only description of the mode */
	case V4L2_CID_VBLANK:
	case V4L2_CID_PIXEL_RATE:
	case V4L2_CID_CAMERA_ORIENTATION:
	case V4L2_CID_CAMERA_SENSOR_ROTATION:
		return 0;
	default:
		return -EINVAL;
	}
}

int sucam_vd_power(struct sucam *cam, bool on)
{
	u8 id[2] = { 0 }, rev[2] = { 0 }, prev[2] = { 0 };
	const struct firmware *fw;
	int i, ret;

	if (!on) {
		if (cam->powered)
			lm_led(cam, false);
		gpiod_set_value_cansleep(cam->gpio[SUCAM_GPIO_RESET], 1);
		gpiod_set_value_cansleep(cam->gpio[SUCAM_GPIO_CAMPOWER], 0);
		cam->powered = false;
		return 0;
	}
	gpiod_set_value_cansleep(cam->gpio[SUCAM_GPIO_CAMPOWER], 1);
	usleep_range(5000, 6000);
	gpiod_set_value_cansleep(cam->gpio[SUCAM_GPIO_RESET], 0);	/* deassert */
	cam->powered = true;	/* so the error path switches the LED driver off */
	ret = vd_wait(cam, VD_FSM, FSM_READY_TO_BOOT);
	if (ret) {
		dev_err(cam->dev, "VD55G0 not responding (%d, fsm %d)\n", ret, vd_read8(cam, VD_FSM));
		goto err;
	}
	ret = vd_read(cam, VD_MODEL_ID, id, 2) ?: vd_read(cam, VD_REVISION, rev, 2);
	if (ret || get_unaligned_le16(id) != 0x4730) {
		dev_err(cam->dev, "not a VD55G0 (%d, id %02x%02x)\n", ret, id[1], id[0]);
		ret = ret ?: -ENODEV;
		goto err;
	}
	ret = request_firmware(&fw, VD_PATCH_FW, cam->dev);
	if (ret || !fw->size || fw->size > VD_PATCH_MAX) {
		dev_err(cam->dev, "sensor patch %s missing or invalid (%d); see tools/extract-vd55g0-patch.py\n",
			VD_PATCH_FW, ret);
		if (!ret)
			release_firmware(fw);
		ret = ret ?: -EINVAL;
		goto err;
	}
	for (i = 0; i < fw->size && !ret; i += 16)
		ret = vd_write(cam, VD_PATCH + i, fw->data + i, min_t(int, 16, fw->size - i));
	release_firmware(fw);
	ret = ret ?: vd_write8(cam, VD_BOOT, BOOT_PATCH_SETUP);
	ret = ret ?: vd_wait(cam, VD_BOOT, 0);
	ret = ret ?: vd_read(cam, VD_FWPATCH_REVISION, prev, 2);
	dev_info(cam->dev, "VD55G0 revision %02x%02x, patch %u.%u (%d)\n",
		 rev[1], rev[0], prev[1], prev[0], ret);
	ret = ret ?: vd_write8(cam, VD_BOOT, BOOT_BOOT);
	ret = ret ?: vd_wait(cam, VD_BOOT, 0);
	ret = ret ?: vd_wait(cam, VD_FSM, FSM_SW_STBY);
	ret = ret ?: vd_write32(cam, VD_EXT_CLOCK, VD_XCLK);
	ret = ret ?: vd_write32(cam, VD_CLK_PLL_MIPI, ir_mbps * 1000000u);
	ret = ret ?: vd_write16(cam, VD_LINE_LENGTH, VD_LLP);
	if (ret) {
		dev_err(cam->dev, "VD55G0 boot failed (%d, fsm %d)\n", ret, vd_read8(cam, VD_FSM));
		goto err;
	}
	return 0;
err:
	sucam_vd_power(cam, false);
	return ret;
}

int sucam_vd_stream(struct sucam *cam, bool on)
{
	int i, ret = 0;

	if (!on) {
		u8 e[2] = { 0 }, fl[2] = { 0 };

		/* what the sensor and the LED driver actually did (first bring-up aid) */
		vd_read(cam, 0x0064, e, 2);
		vd_read(cam, VD_FRAME_LENGTH, fl, 2);
		dev_info(cam->dev, "IR state: exposure %u lines, again %d, dgain %02x, frame %u, mode %d, gpio %02x %02x %02x %02x; LED en %02x flags %02x %02x\n",
			 get_unaligned_le16(e), vd_read8(cam, 0x0066), vd_read8(cam, 0x0069),
			 get_unaligned_le16(fl), vd_read8(cam, VD_EXP_MODE),
			 vd_read8(cam, 0x0467), vd_read8(cam, 0x0468), vd_read8(cam, 0x0469),
			 vd_read8(cam, 0x046a), lm_read(cam, LM_ENABLE), lm_read(cam, LM_FLAGS1),
			 lm_read(cam, LM_FLAGS2));
		vd_write8(cam, VD_STREAMING, 1);
		ret = vd_wait(cam, VD_FSM, FSM_SW_STBY);
		lm_led(cam, false);
		return ret;
	}
	for (i = 0; i < ARRAY_SIZE(vd55g0_windows) && !ret; i++)
		ret = vd_write8(cam, vd55g0_windows[i].reg, vd55g0_windows[i].val);
	if (ir_strobe_gpio < 4 && ir_strobe_gpio != 0) {	/* experiment: strobe on another pin */
		ret = ret ?: vd_write8(cam, VD_GPIO0_CTRL, GPIO_IDLE);
		ret = ret ?: vd_write8(cam, VD_GPIO0_CTRL + ir_strobe_gpio, GPIO_STROBE);
	}
	if (ir_gpio0 >= 0)
		ret = ret ?: vd_write8(cam, VD_GPIO0_CTRL, ir_gpio0);
	if (ir_gpio2 >= 0)
		ret = ret ?: vd_write8(cam, VD_GPIO0_CTRL + 2, ir_gpio2);
	if (ir_ae_roi[1]) {
		ret = ret ?: vd_write16(cam, 0x0436, ir_ae_roi[0]);
		ret = ret ?: vd_write16(cam, 0x043a, ir_ae_roi[1]);
		ret = ret ?: vd_write16(cam, 0x0438, ir_ae_roi[2]);
		ret = ret ?: vd_write16(cam, 0x043c, ir_ae_roi[3]);
	}
	ret = ret ?: vd_write8(cam, VD_FORMAT_CTRL, 10);
	ret = ret ?: vd_write8(cam, VD_OIF_IMG_CTRL, 0x2b);	/* RAW10 */
	/* frame length scales with the bit rate (pixel clock = rate / 10) */
	ret = ret ?: vd_write16(cam, VD_FRAME_LENGTH,
				(u32)SUCAM_IR_FRAME_LENGTH * ir_mbps / 1500);
	if (ret)
		return ret;
	ret = v4l2_ctrl_handler_setup(&cam->ctrls);	/* exposure mode / values / LED */
	ret = ret ?: vd_write8(cam, VD_STBY, 1);
	ret = ret ?: vd_wait(cam, VD_STBY, 0);
	ret = ret ?: vd_wait(cam, VD_FSM, FSM_STREAMING);
	if (ret) {
		dev_err(cam->dev, "VD55G0 stream start failed (%d, fsm %d)\n", ret,
			vd_read8(cam, VD_FSM));
		lm_led(cam, false);
	}
	return ret;
}
