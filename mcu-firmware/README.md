# How to Flash the Latest Neo9labs MCU Firmware

**Warning:** Only flash this firmware on a DE-ELEGOO setup/image, **not** on stock Elegoo software.

Accessing the [**Hidden microSD slot**](https://github.com/neo9labs/Neo9labes/wiki/Hidden-microSD-Slot-Access) (later model N4+Pro & Plus / Max)

## How to Flash Updated Klipper MCU Firmware:
(Only do this if you have the Neo9labs Image or have De-Elegood your machine)

```
~/Neo9labs/Neo9labs.sh
```
- Select menu Option 4
- Then select option 4 `ALL`
- Note: if you don't have a pico accelerometer `Skip` this step when prompted.

## How to revert to Original Elegoo MCU Firmware

- Format a MicroSD card to FAT32
- Download this firmware file [**ElegooSD-restore.bin**](https://github.com/neo9labs/Neo9labes/raw/main/mcu-firmware/ElegooSD-restore.bin)
- Move the file to the root of the MicroSD, duplicate the file, name one X_4.bin, and the other elegoo_k1.bin
- Safely Eject the MicroSD
- Ensure your printer is powered off
- Insert the MicroSD into your printer 
- Power on the printer and wait 2min

More info in the [**Wiki**](https://github.com/neo9labs/Neo9labes/wiki/)
