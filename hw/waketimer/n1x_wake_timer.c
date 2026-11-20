// SPDX-License-Identifier: GPL-2.0
/*
 * n1x_wake_timer - wake the Lenovo Yoga 83N7 (NVIDIA N1X) from s2idle on a timer.
 *
 * The machine has no working wake alarm: rtc-efi cannot wake it and the ACPI
 * Time-and-Alarm device (ACPI000E) is a stub in the EC.  The SoC does have
 * eight always-on memory-mapped generic-timer frames (GTDT, block 0x1C430000);
 * Linux uses frame 0 as its broadcast timer.  This module takes a spare frame
 * and uses its physical timer as a wake source.
 *
 *   /sys/module/n1x_wake_timer/parameters/seconds  write N: fire once in N s (0 = cancel)
 *   /sys/module/n1x_wake_timer/parameters/period   N > 0: arm N s at every suspend
 *   /sys/module/n1x_wake_timer/parameters/fires    timer wakes so far
 */
#include <linux/module.h>
#include <linux/acpi.h>
#include <linux/dmi.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/pm_wakeup.h>
#include <linux/suspend.h>
#include <linux/delay.h>

#define CNTCTL_BASE	0x1C430000UL
#define FRAME_BASE(n)	(0x1C440000UL + (n) * 0x10000UL)
#define FRAME_GSI(n)	(0x2DA + (n))		/* physical timer interrupt */

#define CNTNSAR		0x04
#define CNTTIDR		0x08
#define CNTACR(n)	(0x40 + (n) * 4)
#define CNTACR_RPCT	BIT(0)
#define CNTACR_RWPT	BIT(5)

#define CNTPCT_LO	0x00
#define CNTPCT_HI	0x04
#define CNTFRQ		0x10
#define CNTP_CVAL_LO	0x20
#define CNTP_CVAL_HI	0x24
#define CNTP_CTL	0x2c
#define CTL_ENABLE	BIT(0)
#define CTL_IMASK	BIT(1)
#define CTL_ISTATUS	BIT(2)

static unsigned int frame = 1;
module_param(frame, uint, 0444);
static unsigned int period;
module_param(period, uint, 0644);
static unsigned int fires;
module_param(fires, uint, 0444);

static void __iomem *base;
static u64 rate;
static int irq = -1;
static struct wakeup_source *ws;
static bool fired;
static u64 deadline;
static DEFINE_SPINLOCK(lock);

static u64 now(void)
{
	u32 hi, lo, hi2;

	do {
		hi = readl(base + CNTPCT_HI);
		lo = readl(base + CNTPCT_LO);
		hi2 = readl(base + CNTPCT_HI);
	} while (hi != hi2);
	return ((u64)hi << 32) | lo;
}

static void disarm(void)
{
	unsigned long f;

	spin_lock_irqsave(&lock, f);
	writel(0, base + CNTP_CTL);
	deadline = 0;
	spin_unlock_irqrestore(&lock, f);
}

static void arm(unsigned int secs)
{
	unsigned long f;
	u64 cval;

	spin_lock_irqsave(&lock, f);
	writel(0, base + CNTP_CTL);
	cval = now() + (u64)secs * rate;
	writel(lower_32_bits(cval), base + CNTP_CVAL_LO);
	writel(upper_32_bits(cval), base + CNTP_CVAL_HI);
	deadline = cval;
	fired = false;
	writel(CTL_ENABLE, base + CNTP_CTL);
	spin_unlock_irqrestore(&lock, f);
}

static irqreturn_t wake_irq(int irqn, void *data)
{
	if (!(readl(base + CNTP_CTL) & CTL_ISTATUS))
		return IRQ_NONE;
	writel(0, base + CNTP_CTL);
	deadline = 0;
	fired = true;
	fires++;
	pm_wakeup_ws_event(ws, 3000, true);
	return IRQ_HANDLED;
}

static int seconds_set(const char *val, const struct kernel_param *kp)
{
	unsigned int s;
	int ret = kstrtouint(val, 0, &s);

	if (ret)
		return ret;
	if (s)
		arm(s);
	else
		disarm();
	return 0;
}

static int seconds_get(char *buf, const struct kernel_param *kp)
{
	u64 d = READ_ONCE(deadline), n = now();

	return sysfs_emit(buf, "%llu\n", d > n ? div64_u64(d - n, rate) : 0ULL);
}

static const struct kernel_param_ops seconds_ops = { .set = seconds_set, .get = seconds_get };
module_param_cb(seconds, &seconds_ops, NULL, 0644);

static int pm_cb(struct notifier_block *nb, unsigned long ev, void *p)
{
	switch (ev) {
	case PM_SUSPEND_PREPARE:
		if (period)
			arm(period);
		break;
	case PM_POST_SUSPEND:
		if (fired)
			pr_info("n1x_wake_timer: woke the system (wake #%u)\n", fires);
		if (period)
			disarm();
		fired = false;
		break;
	}
	return NOTIFY_OK;
}
static struct notifier_block pm_nb = { .notifier_call = pm_cb };

static int __init wt_init(void)
{
	void __iomem *ctl;
	u32 tidr, nsar, acr;
	u64 a, b;
	int ret;

	if (!dmi_match(DMI_PRODUCT_NAME, "83N7"))
		return -ENODEV;
	if (frame < 1 || frame > 7)
		return -EINVAL;

	ctl = ioremap(CNTCTL_BASE, 0x1000);
	if (!ctl)
		return -ENOMEM;
	tidr = readl(ctl + CNTTIDR);
	nsar = readl(ctl + CNTNSAR);
	acr = readl(ctl + CNTACR(frame));
	iounmap(ctl);
	pr_info("n1x_wake_timer: frame %u CNTTIDR=%08x CNTNSAR=%08x CNTACR=%02x\n", frame, tidr, nsar, acr);
	if (!(tidr & BIT(frame * 4)) || (~acr & (CNTACR_RPCT | CNTACR_RWPT))) {
		pr_err("n1x_wake_timer: frame %u not usable\n", frame);
		return -ENODEV;
	}

	base = ioremap(FRAME_BASE(frame), 0x1000);
	if (!base)
		return -ENOMEM;
	rate = readl(base + CNTFRQ);
	if (!rate)
		rate = 1000000000;
	a = now();
	msleep(20);
	b = now();
	pr_info("n1x_wake_timer: rate %llu Hz, counter advanced %llu in 20 ms, CTL=%x\n",
		rate, b - a, readl(base + CNTP_CTL));
	if (b == a) {
		ret = -ENODEV;
		goto unmap;
	}
	writel(0, base + CNTP_CTL);

	ws = wakeup_source_register(NULL, "n1x-wake-timer");
	if (!ws) {
		ret = -ENOMEM;
		goto unmap;
	}
	irq = acpi_register_gsi(NULL, FRAME_GSI(frame), ACPI_LEVEL_SENSITIVE, ACPI_ACTIVE_HIGH);
	if (irq < 0) {
		ret = irq;
		goto unws;
	}
	ret = request_irq(irq, wake_irq, IRQF_NO_SUSPEND, "n1x-wake-timer", &pm_nb);
	if (ret)
		goto unws;
	register_pm_notifier(&pm_nb);
	pr_info("n1x_wake_timer: ready, irq %d (GSI %u)\n", irq, FRAME_GSI(frame));
	return 0;
unws:
	wakeup_source_unregister(ws);
unmap:
	iounmap(base);
	return ret;
}

static void __exit wt_exit(void)
{
	unregister_pm_notifier(&pm_nb);
	disarm();
	free_irq(irq, &pm_nb);
	wakeup_source_unregister(ws);
	iounmap(base);
}

module_init(wt_init);
module_exit(wt_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Timer wake from s2idle for the Lenovo Yoga 83N7 (NVIDIA N1X)");
