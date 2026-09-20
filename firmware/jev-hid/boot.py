# Runs once, before USB is brought up — which is the only moment the HID
# descriptor can be changed. code.py cannot do this; by the time it runs the
# Mac has already been told what kind of device this is.
#
# The important part is the mouse. CircuitPython's stock mouse is RELATIVE: it
# reports "moved 3 left, 2 up", so putting the cursor somewhere exact means
# dead-reckoning from wherever it currently is, and any dropped report leaves
# you permanently offset. Declaring it ABSOLUTE means jev says "go to this
# point" and the pointer is there — which is what the phone is actually asking
# for, since it sends a normalised 0…1 position off a picture of the screen.

import usb_hid

KEYBOARD_DESCRIPTOR = bytes((
    0x05, 0x01,        # Usage Page (Generic Desktop)
    0x09, 0x06,        # Usage (Keyboard)
    0xA1, 0x01,        # Collection (Application)
    0x85, 0x01,        #   Report ID (1)
    0x05, 0x07,        #   Usage Page (Keyboard)
    0x19, 0xE0,        #   Usage Minimum (LeftControl)
    0x29, 0xE7,        #   Usage Maximum (Right GUI)
    0x15, 0x00,        #   Logical Minimum (0)
    0x25, 0x01,        #   Logical Maximum (1)
    0x75, 0x01,        #   Report Size (1)
    0x95, 0x08,        #   Report Count (8)
    0x81, 0x02,        #   Input (Data, Variable, Absolute) — modifier byte
    0x95, 0x01,        #   Report Count (1)
    0x75, 0x08,        #   Report Size (8)
    0x81, 0x01,        #   Input (Constant) — reserved byte
    0x95, 0x06,        #   Report Count (6)
    0x75, 0x08,        #   Report Size (8)
    0x15, 0x00,        #   Logical Minimum (0)
    0x26, 0xFF, 0x00,  #   Logical Maximum (255)
    0x05, 0x07,        #   Usage Page (Keyboard)
    0x19, 0x00,        #   Usage Minimum (0)
    0x2A, 0xFF, 0x00,  #   Usage Maximum (255)
    0x81, 0x00,        #   Input (Data, Array) — six key slots
    0xC0,              # End Collection
))

MOUSE_DESCRIPTOR = bytes((
    0x05, 0x01,        # Usage Page (Generic Desktop)
    0x09, 0x02,        # Usage (Mouse)
    0xA1, 0x01,        # Collection (Application)
    0x85, 0x02,        #   Report ID (2)
    0x09, 0x01,        #   Usage (Pointer)
    0xA1, 0x00,        #   Collection (Physical)
    0x05, 0x09,        #     Usage Page (Button)
    0x19, 0x01,        #     Usage Minimum (1)
    0x29, 0x03,        #     Usage Maximum (3)
    0x15, 0x00,        #     Logical Minimum (0)
    0x25, 0x01,        #     Logical Maximum (1)
    0x95, 0x03,        #     Report Count (3)
    0x75, 0x01,        #     Report Size (1)
    0x81, 0x02,        #     Input (Data, Variable, Absolute) — buttons
    0x95, 0x01,        #     Report Count (1)
    0x75, 0x05,        #     Report Size (5)
    0x81, 0x03,        #     Input (Constant) — padding to a byte
    0x05, 0x01,        #     Usage Page (Generic Desktop)
    0x09, 0x30,        #     Usage (X)
    0x09, 0x31,        #     Usage (Y)
    0x16, 0x00, 0x00,  #     Logical Minimum (0)
    0x26, 0xFF, 0x7F,  #     Logical Maximum (32767)
    0x75, 0x10,        #     Report Size (16)
    0x95, 0x02,        #     Report Count (2)
    0x81, 0x02,        #     Input (Data, Variable, ABSOLUTE) — the whole point
    0x09, 0x38,        #     Usage (Wheel)
    0x15, 0x81,        #     Logical Minimum (-127)
    0x25, 0x7F,        #     Logical Maximum (127)
    0x75, 0x08,        #     Report Size (8)
    0x95, 0x01,        #     Report Count (1)
    0x81, 0x06,        #     Input (Data, Variable, Relative) — wheel stays relative
    0xC0,              #   End Collection
    0xC0,              # End Collection
))

keyboard = usb_hid.Device(
    report_descriptor=KEYBOARD_DESCRIPTOR,
    usage_page=0x01,
    usage=0x06,
    report_ids=(1,),
    in_report_lengths=(8,),
    out_report_lengths=(1,),
)

mouse = usb_hid.Device(
    report_descriptor=MOUSE_DESCRIPTOR,
    usage_page=0x01,
    usage=0x02,
    report_ids=(2,),
    # buttons(1) + x(2) + y(2) + wheel(1)
    in_report_lengths=(6,),
    out_report_lengths=(0,),
)

usb_hid.enable((keyboard, mouse))
