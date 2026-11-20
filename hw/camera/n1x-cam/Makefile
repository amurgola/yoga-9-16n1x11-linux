# Lenovo Yoga 9 2-in-1 16N1X11 (83N7) front camera: port of ikegam/surface-ultra-camera.
# Build against the running kernel; load with insmod after n1x_ccu_boot go=1 has booted the CCU.
KDIR ?= /lib/modules/$(shell uname -r)/build
obj-m := n1x_yoga_cam.o
n1x_yoga_cam-y := sucam_main.o sucam_hw.o sucam_vd55g0.o sucam_mc.o

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
