# MB85RC Library

This library is designed to help you manage a number of Ferroelectric RAM (FRAM) chips, such as the Fujitsu MB85RC256V. Each chip contains non-volatile storage with a read/write endurance and access speed well in excess of standard Flash storage, though at the cost of a much lower bytes per dollar value. For more information on FRAM see [Wikipedia](https://en.wikipedia.org/wiki/Ferroelectric_RAM). 

The MB85RC256V is the prime component of Adafruit’s [I&sup2;C Non-Volatile FRAM Breakout](http://www.adafruit.com/product/1895). This breakout includes 32KB of FRAM, but FRAM chips are available in a range of capacities. The MB85RC256V is available in 4, 16, 64, 256, 512 and 1024kb, for example. Up to eight MB85RC256Vs can be connected to each imp I&sup2;C bus. This is limited in comparison with Flash, but useful for applications that need to preserve data across device restarts.

Each FRAM’s storage is accessed at the byte level; each byte has a 16-bit address. The class supports writing to and reading from chips and store on a byte-by-byte basis. It also supports the writing of a blob to a chip or store, and multiple bytes can be read back into a blob. As such, the classes are a good partner for Electric Imp’s [serializer class](https://electricimp.com/docs/libraries/utilities/), which converts Squirrel objects into binary data for storage.

**To add this libraries to your project, add** `#require "MB85RC.class.nut:1.0.0"` **to the top of your device code**

### MB85RC256V Addressing

Each MB85RC256V has three pins through which its I&sup2;C address is set: A0, A1 and A2. These are internally pulled down to 0, but can be raised to 1 by applying 3.3V to the pin. The chip’s base address is 0xA0; setting any or all of the address pins increases this by 2 with each pin set as follows:

| Base | A2 | A1 | A0 | I&sup2;C Address |
| --- | --- | --- | --- | --- |
| 1010 | 0 | 0 | 0 | 0xA0 |
| 1010 | 0 | 0 | 1 | 0xA2 |
| 1010 | 0 | 1 | 0 | 0xA4 |
| 1010 | 0 | 1 | 1 | 0xA6 |
| 1010 | 0 | 1 | 1 | 0xA6 |
| 1010 | 1 | 0 | 0 | 0xA8 |
| 1010 | 1 | 0 | 1 | 0xAA |
| 1010 | 1 | 1 | 0 | 0xAC |
| 1010 | 1 | 1 | 1 | 0xAE |

&nbsp;<br>As such, you can address up to eight MB85RC256Vs per bus. Remember, bit 0 of the address is set for write operations and cleared for reads.

## MB85RC Usage

### Constructor: MB85RC(*i2cBus*, *i2cAddress*, *size*[, *writeProtectPin*][, *debug*])

The constructor takes a **configured** imp I&sup2;C bus. The chip’s I&sup2C; address is required as the second parameter it defaults to 0xA0 *(see [above](#mb85rc256v-addressing))*. The third parameter, *size*, is used to specify the FRAM chip’s capacity in kb (kilobits), eg. 256 for 32KB FRAMs.

The fourth parameter, *writeProtectPin*, is optional and may be set to any spare [imp pin object](https://electricimp.com/docs/api/hardware/pin/), which will be configured as a digital output in order to control the MB85RC256V’s write-protect pin. When this pin is set to 1 (logic high), the chip is temporarily write-protected; attempts to write data to the chip will have no effect. Note that no warning is given if data is being written to a write-protected chip; the data written is ignored. Write-protect remains in force until the pin is set to 0 (logic low) or the chip is power-cycled.

The fourth parameter, *debug*, is also optional: it defaults to `false`, but if you pass `true`, you will receive progress messages during the various class methods’ operation.

#### Example

```
#require "MB85RC.class.nut:1.0.0"

const BASE_I2C_ADDRESS = 0xA0;

// Configure I2C bus
local i2c = hardware.i2c89;
i2c.configure(CLOCK_SPEED_400_KHZ);

// Configure write-protect pin
local wpin = hardware.pin7;

// Configure FRAM chip
local fram = MB85RC(i2c, BASE_I2C_ADDRESS, 256, wpin);
```

## MB85RC Methods

The class provides two sets of methods: its own and a set which mimic the behaviour of the imp API [**hardware.spiflash**](https://electricimp.com/docs/api/hardware/spiflash/) class. The first group is covered first, the second [described below](#enable).

### clear(*value*)

This method clears the chip’s contents to the passed unsigned 8-bit value. If the value passed is not an integer in the range 0&ndash;255, the value 0 is substituted for it.

#### Example

```
// Fill fram with EOF markers
fram.clear(EOF_MARKER);
```

### readByte(*address*)

This method reads and returns the unsigned 8-bit value located at *address*. The returned value is a single-character string.

If the passed address is outside the chip’s address space, the method returns the value -1. This value may also be returned if there has been an I&sup2;C read error &ndash; consult the [i2c.readerror()](https://electricimp.com/docs/api/hardware/i2c/readerror/) documentation for possible values and their causes.

#### Example

```
data <- [];

if (fram.readByte(CONTENT_SET_MARKER_ADDRESS) == CONTENT_SET_MARKER) {
    // Data stored previously, so read it in
    local count = fram.readByte(CONTENT_COUNT_ADDRESS);
    for (local i = 0 ; i < count ; ++i) {
    	local d = fram.readBlob(CONTENT_START_ADDRESS + (i * CONTENT_LENGTH), CONTENT_LENGTH);
    	data.append(d);
    }
}
```

### writeByte(*address*, *value*)

This method writes the passed *value* to *address*. If the passed address is outside the chip’s address range, the method returns the value -1; this will also be returned if *value* does not lie in the range 0x00&ndash;0xFF. If there has been an I&sup2;C write error, -1 or another negative integer will be returned &ndash; consult the [i2c.readerror()](https://electricimp.com/docs/api/hardware/i2c/readerror/) documentation for possible values and their causes. The method returns 0 to indicate a successful transmission.

For an example, see [*writeBlob()*](#writeblob-startaddress-data-wrap).

### readBlob(*startAddress*, *numBytes*)

This method returns a blob containing *numBytes* of binary data read from the chip, starting at *address**. If either the address or the number of bytes to read are out of range or incorrectly specified, the method returns the value -1.

If the attempt to generate the blob’s contents tries to read beyond the chip’s top address, the blob will be returned containing only the number of bytes that were available to read. So if your code asks for the 128 bytes starting at 0x7FF0 in a 32KB chip, the returned blob will only be 15 bytes long.

For an example, see [*readByte()*](#readbyte-address).

### writeBlob(*startAddress*, *data*[, *wrap*])

This method writes the passed blob, *data*, starting at *address*. If the address is out of range, or the data incorrectly specified, the method returns the value -1. The third parameter, *wrap*, is optional and defaults to `false`. If *wrap* is set to `true`, then should there be an attempt to write data beyond the chip’s top address, then those bytes will be written to address 0x0000 and up until the blob is depleted.

#### Example

```
// Back-up the blobs in the data array
local error = 0;
foreach (b in data) {
    error = fram.writeBlob(CONTENT_START_ADDRESS + (i * CONTENT_LENGTH), b);
    if (error != 0) {
        server.log("Data write error – bailing);
        break;
    }
}

if (error == 0) {
    // Data written successfully. So record number of items...
    fram.writeByte(CONTENT_COUNT_ADDRESS, data.len());

    // And record that content has been written
    fram.writeByte(CONTENT_SET_MARKER_ADDRESS, CONTENT_SET_MARKER);
}
```

### setWriteProtectPin(*writeProPin*[, *startState*])

This method sets the imp pin connected to the MB85RC256V’s write-protect pin. The second parameter, *startState*, is optional: it defaults to 0 (write protect off) but can be set to 1 to immediately write-protect the chip.

See *setWriteProtect()*, below, for a usage example.

### setWriteProtect(*state*)

This method sets or unsets the chip’s write-protect pin to the specified *state*, which may be the integer 1 or the boolean `true` (write protect on), or 0 or `false` (write protect off). If the pin is set (or left unchanged because the new value of *state* matches the current state of the pin), the method returns `true`. It returns `false` if an error has been encountered, ie. no write-protect pin has been specified for this chip.

#### Example

```
// frams contains three MB85RC256V chips
local fram = frams.framFromIndex(1);
fram.setWriteProtectPin(hardware.pin7);

// Zero the store
frams.clearStore(0x00);

// Write-protect chip 1
fram.setWriteProtect(true);

// Write 1 to the entire store
frams.clearStore(0x01);

// Chips 0 and 2 will now contain 1s; chip 1 will contain 0s
````

### maxAddress()

This method returns the chip’s top memory address + 1. For example, if the chip has 32KB of storage, its 16-bit address space runs from 0x0000 to 0x7FFF. Calling *maxAddress()* will return 0x8000.

### csize()

This method returns the chip’s size in kilobits.

### checkFramInfo()

This method reads back the MB85RC256V’s product and manufacturer IDs. If either yield unexpected values &ndash; the correct values are 0x00A for the manufacturer ID and 0x510 for the product ID &ndash; an error is posted in the log, and the method returns `false`. Otherwise it returns `true`.

#### Example

```
for (local i = 0 ; i < numFrams ; ++i) {
    local fram = frams.framFromIndex(i);
    server.log("Checking FRAM chip " + i);
    local error = false;
    if (fram != null) {
        error = fram.checkFramInfo();
        if (!error) break;
    }
}
```

## hardware.spiflash Methods

The following methods provide a measure of compatibility with the imp API’s [**hardware.spiflash**](https://electricimp.com/docs/api/hardware/spiflash/) class. This has been done to assist developers wishing to migrate from spiflash because of its limitations, such as the need to erase at the sector level before a single bit can be written to that sector. 

### enable()

This method soft-enables the MB85RC256V after a *disable()* operation.

### disable()

This method soft-disables the MB85RC256V. Read and write operations carried out using [**hardware.spiflash**](https://electricimp.com/docs/api/hardware/spiflash/)-compatible methods (but not the class’ own methods, above) will not be permitted.

### erasesector(*boundAddr*)

This method zeroes the MB85RC256V’s storage in blocks of 4KB. The sector’s address **must** be on a 4KB boundary (0x0000, 0x1000, etc) or a runtime error will be thrown.

### chipid()

This method returns the MB85RC256V chip’s I&sup2;C address.

### size()

This method returns the MB85RC256V chip’s capacity in bytes.

### write(*addr*, *source*[, *flags*][, *start*][, *end*])

This method writes the blob passed into *source* at the address *addr*. The optional parameters *start* and *end* specify start and end points within *source* which mark the bytes that will be transferred. For example, if the blob passed into *source* is 512 bytes long, but you only wish to write the first 128 bytes to FRAM, you would use:

```
fram.write(0, source, 0, 0, 128);
```

The *flags* parameter allows you to trigger pre- and post-verification of writes *(see [**hardware.spiflash.write()**](https://electricimp.com/docs/api/hardware/spiflash/write/)*.

### read(*addr*, *numBytes*)

This method creates a new blob, populates it with *numBytes* of data read from FRAM (starting at address *addr*) and returns it.

### readintoblob(*addr*, *tBlob*, *numBytes*)

This method reads *numBytes* of data read from FRAM (starting at address *addr*) and writes it into the blob passed into the second parameter, *tBlob*.

## License

The MB85RC library is licensed under the [MIT License](https://github.com/electricimp/MB85RC/blob/master/LICENSE).
