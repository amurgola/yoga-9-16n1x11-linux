// SPDX-License-Identifier: GPL-2.0
/*
 * Lenovo Yoga 9 2-in-1 16N1X11 (83N7): F4 microphone-mute LED.
 *
 * The LED hangs off the EC. The firmware exposes it through the "LSK20" WMI device:
 * \_SB.WMIU.WMSK(0, 2, Buffer{1}) = on, Buffer{2} = off (EC command 0x4D / 0x4E at
 * 0xFE0B0200, sent over the FF-A EC-RAM service). There is no WMI bus driver for this
 * device on arm64, so evaluate the method directly and expose a standard LED:
 *   /sys/class/leds/platform::micmute   (driven from user space, see n1x-micmute-led)
 */
#include <linux/acpi.h>
#include <linux/dmi.h>
#include <linux/input.h>
#include <linux/input/sparse-keymap.h>
#include <linux/leds.h>
#include <linux/module.h>

#define WMIU_PATH "\\_SB.WMIU"
#define WMSK_PATH "\\_SB.WMIU.WMSK"

/*
 * Hotkeys. The top-row functions that the keyboard does not send as HID keys arrive as
 * Notify(\_SB.WMIU, 0xD0); _WED(0xD0) then returns the key code (EC0.LSK2, 0x3E..0x49 in
 * this DSDT). Codes follow ideapad-laptop's WMI table where known: 0x3E = microphone mute.
 * Unmapped codes are logged so the table can grow.
 */
static struct input_dev *hotkeys;
static acpi_handle wmiu;

static const struct key_entry hotkey_map[] = {
	{ KE_KEY, 0x3e, { KEY_MICMUTE } },
	{ KE_END }
};

static void wmiu_notify(acpi_handle h, u32 event, void *data)
{
	union acpi_object arg = { .integer = { ACPI_TYPE_INTEGER, event } };
	struct acpi_object_list list = { 1, &arg };
	unsigned long long code = 0;

	if (event != 0xd0)
		return;
	if (ACPI_FAILURE(acpi_evaluate_integer(h, "_WED", &list, &code)))
		return;
	if (!sparse_keymap_report_event(hotkeys, code, 1, true))
		pr_info("n1x_yoga_leds: unmapped hotkey code 0x%llx\n", code);
}

static int micmute_set(struct led_classdev *cdev, enum led_brightness b)
{
	u8 fid = b ? 1 : 2;
	union acpi_object args[3] = {
		{ .integer = { ACPI_TYPE_INTEGER, 0 } },
		{ .integer = { ACPI_TYPE_INTEGER, 2 } },
		{ .buffer = { ACPI_TYPE_BUFFER, 1, &fid } },
	};
	struct acpi_object_list list = { 3, args };
	unsigned long long ret = 0;
	acpi_status st;

	st = acpi_evaluate_integer(NULL, WMSK_PATH, &list, &ret);
	if (ACPI_FAILURE(st))
		return -EIO;
	return ret ? -EIO : 0;
}

static struct led_classdev micmute_led = {
	.name = "platform::micmute",
	.max_brightness = 1,
	.brightness_set_blocking = micmute_set,
};

static const struct dmi_system_id yoga_ids[] = {
	{ .matches = { DMI_MATCH(DMI_SYS_VENDOR, "LENOVO"), DMI_MATCH(DMI_PRODUCT_NAME, "83N7") } },
	{ }
};
MODULE_DEVICE_TABLE(dmi, yoga_ids);

static int __init n1x_yoga_leds_init(void)
{
	acpi_handle h;

	if (!dmi_check_system(yoga_ids))
		return -ENODEV;
	int ret;

	if (ACPI_FAILURE(acpi_get_handle(NULL, WMSK_PATH, &h)) ||
	    ACPI_FAILURE(acpi_get_handle(NULL, WMIU_PATH, &wmiu)))
		return -ENODEV;

	hotkeys = input_allocate_device();
	if (!hotkeys)
		return -ENOMEM;
	hotkeys->name = "Lenovo Yoga 83N7 hotkeys";
	hotkeys->phys = "n1x-yoga/input0";
	hotkeys->id.bustype = BUS_HOST;
	ret = sparse_keymap_setup(hotkeys, hotkey_map, NULL);
	if (!ret)
		ret = input_register_device(hotkeys);
	if (ret) {
		input_free_device(hotkeys);
		return ret;
	}
	if (ACPI_FAILURE(acpi_install_notify_handler(wmiu, ACPI_DEVICE_NOTIFY, wmiu_notify, NULL))) {
		input_unregister_device(hotkeys);
		return -EBUSY;
	}
	ret = led_classdev_register(NULL, &micmute_led);
	if (ret) {
		acpi_remove_notify_handler(wmiu, ACPI_DEVICE_NOTIFY, wmiu_notify);
		input_unregister_device(hotkeys);
	}
	return ret;
}

static void __exit n1x_yoga_leds_exit(void)
{
	led_classdev_unregister(&micmute_led);
	acpi_remove_notify_handler(wmiu, ACPI_DEVICE_NOTIFY, wmiu_notify);
	input_unregister_device(hotkeys);
}

module_init(n1x_yoga_leds_init);
module_exit(n1x_yoga_leds_exit);
MODULE_DESCRIPTION("Lenovo Yoga 83N7 (NVIDIA N1X) microphone-mute LED and EC hotkeys");
MODULE_LICENSE("GPL");
