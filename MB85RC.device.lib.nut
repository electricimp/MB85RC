// The MIT License (MIT)
//
// Copyright (c) 2015-18 Electric Imp, Inc.
//
// SPDX-License-Identifier: MIT
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// CONSTANTS
// hardware.spiflash compatibility constants
const MB85RC_SPIFLASH_PREVERIFY = 2;
const MB85RC_SPIFLASH_POSTVERIFY = 1;
const MB85RC_SPIFLASH_NOERROR = 0;

// MB85RC constants
const MB85RC_CHIP_INFO_OPCODE = 0xF8;

class MB85RC {

    // Represents a single Fujitsu MB85RC FRAM chip with an I2C interface
    // See https://github.com/electricimp/FramStore for a class for combining
    // multiple chips onto a single address space

    static VERSION = "2.0.0";

    _i2c = null;
    _i2cAddr = null;
    _wPin = null;
    _wPinState = 0;
    _enabled = false;
    _debug = false;
    _minAddress = 0x0000;
    _maxAddress = 0x7FFF;
    _size = 256;

    constructor (i2cBus = null, i2cAddress = 0xA0, size = 256, writeProtectPin = null, debug = false) {

        // No imp I2C object passed in - throw a runtime error
        if (i2cBus == null) throw "MB85RC() requires a non-null imp I2C object";

        if (writeProtectPin != null) {
            // A write-protect pin has been passed; configure it to low – write-permitted
            _wPin = writeProtectPin;
            _wPinState = 0;
            _wPin.configure(DIGITAL_OUT, _wPinState);
        }

        // Check that the 'size' parameter's argument is a permitted size (in KB)
        local sizes = [4, 16, 64, 256, 512, 1024];
        local ok = false;
        foreach (aSize in sizes) {
            if (size == aSize) {
                _maxAddress = ((size / 8) * 1024) - 1;
                _size = size;
                ok = true;
            }
        }

        // Unavailable size supplied - throw a runtime error
        if (!ok) throw ("MB85RC() has been passed an invalid FRAM capacity: " + size + "Kb (" + (size / 8) + "KB)");

        // Set the object properties
        _i2c = i2cBus;
        _i2cAddr = i2cAddress;
        _debug = debug;
        _enabled = true;

        // Check that we have an MB85RC chip connected. Throw a runtime error if not
        if (!checkFramInfo()) throw format("No MB85RC found at I2C address 0x%02X", i2cAddress);
    }

    // ********** IMP API HARDWARE.SPIFLASH COMPATIBILITY METHODS **********
    // *********************************************************************

    function enable() {

        // Set the internal FRAM enabled flag
        _enabled = true;
    }

    function disable() {

        // Unset the internal FRAM enabled flag
        _enabled = false;
    }

    function erasesector(boundAddr = 0) {

        // Erase a 4kB sector of storage
        // NOTE This is not a FRAM requirement but is provided to deliver
        //      compatibility with the imp API's hardware.spiflash object
        if (!_enabled) {
            // The code is trying to work with a disabled MB85RC,
            // so just issue a warning to allow the host app to recover
            server.error("MB85RC.erasesector() FRAM must enabled to erase a sector");
            return null;
        }

        if (boundAddr % 4096 != 0) {
            // The code is trying to erase across 4KB boundaries,
            // so just issue a warning to allow the host app to recover
            server.error("MB85RC.erasesector() FRAM sector to erase must be on 4KB boundary");
            return;
        }

        if (boundAddr >= _maxAddress || boundAddr < 0) {
            // The code is trying to erase beyond its size,
            // so just issue a warning to allow the host app to recover
            server.error("MB85RC.erasesector() FRAM sector to erase out of range");
            return;
        }

        for (local i = boundAddr ; i < boundAddr + 4096 ; i++) {
            if (i < _maxAddress) writeByte(i, 0x00);
        }
    }

    function chipid () {

        // Return the chip's I2C address as its ID
        return _i2cAddr;
    }

    function size() {

        // Return the chip's size in bytes
        return ((_size / 8) * 1024);
    }

    function write(addr = -1, source = null, flags = 0, start = -1, end = -1) {

        // Writes a blob into the MB85RC at the specified address
        if (flags == null) flags = MB85RC_SPIFLASH_NOERROR;

        if (!_enabled) {
            // The code is trying to work with a disabled MB85RC,
            // so just issue a warning to allow the host app to recover
            server.error("MB85RC.write() FRAM must be enabled to write");
            return (flags != MB85RC_SPIFLASH_NOERROR ? MB85RC_SPIFLASH_PREVERIFY : MB85RC_SPIFLASH_NOERROR);
        }

        if (addr < 0 || addr > _maxAddress) {
            // The code is trying to write beyond its size,
            // so just issue a warning to allow the host app to recover
            server.error("MB85RC.write() address out of range");
            return (flags != MB85RC_SPIFLASH_NOERROR ? MB85RC_SPIFLASH_PREVERIFY : MB85RC_SPIFLASH_NOERROR);
        }

        if (source == null) {
            // The code is trying to write without specifying a data source,
            // so just issue a warning to allow the host app to recover
            server.error("MB85RC.write() null data source");
            return (flags != MB85RC_SPIFLASH_NOERROR ? MB85RC_SPIFLASH_PREVERIFY : MB85RC_SPIFLASH_NOERROR);
        }

        local t = typeof source;
        if (t != "blob" && t != "string") {
            // The code is trying to write without specifying a valid data source,
            // so just issue a warning to allow the host app to recover
            server.error("MB85RC.write() invalid data source");
            return (flags != MB85RC_SPIFLASH_NOERROR ? MB85RC_SPIFLASH_PREVERIFY : MB85RC_SPIFLASH_NOERROR);
        }

        if (start < 0 || start >= source.len()) start = 0;
        if (end > source.len() || end < 0) end = source.len();
        if (start == end) {
            // Set 'start' and 'end to +/1 from the set location
            if (start < source.len()) {
                end = (start < source.len() - 1) ? start + 1 : start;
            } else {
                start = end - 1;
                if (start < 0) start = 0;
            }
        } else if (start > end) {
            // Flip 'start' and 'end' around so that
            // they are in the correct numerical order
            local a = end;
            end = start;
            start = a;
        }

        if (t == "string") {
            local b = blob(source.len());
            b.writestring(source);
            source = b;
        }

        source.seek(start, 'b');
        local b = source.readblob(end - start);
        local r = writeBlob(addr, b);

        if (r != 0) {
            server.error("MB85RC.write() I2C error " + r);
            return (flags != MB85RC_SPIFLASH_NOERROR ? MB85RC_SPIFLASH_PREVERIFY : MB85RC_SPIFLASH_NOERROR);
        }

        if (flags == MB85RC_SPIFLASH_POSTVERIFY) {
            // Do write verify
            local c = readBlob(addr, source.len());
            if (c == -1) return MB85RC_SPIFLASH_POSTVERIFY;

            for (local i = 0 ; i < b.len() ; ++i) {
                if (i < c.len() && c[i] != b[i]) return (flags != MB85RC_SPIFLASH_NOERROR ? MB85RC_SPIFLASH_PREVERIFY : MB85RC_SPIFLASH_NOERROR);
            }
        } else {
            return MB85RC_SPIFLASH_NOERROR;
        }

        return MB85RC_SPIFLASH_NOERROR;
    }

    function read(addr = 0, numBytes = 1) {

        // Read the specified number of bytes from the specified address
        // NOTE returns 'null' if an error has taken place
        if (!_enabled) {
            // The code is trying to write without specifying a data source,
            // so just issue a warning to allow the host app to recover
            server.error("MB85RC.read() FRAM must be enabled to read");
            return null;
        }

        if (addr < 0 || addr >= _maxAddress) {
            // The code is trying to read beyond its size,
            // so just issue a warning to allow the host app to recover
            server.error("MB85RC.read() FRAM read out of range");
            return null;
        }

        if (_maxAddress - addr < numBytes) numBytes = _maxAddress - addr;
        local r = readBlob(addr, numBytes);
        return (r == -1 ? null : r);
    }

    function readintoblob(addr = 0, tBlob = null, numBytes = 1) {

        // Read the specified number of bytes from the specified address
        // and write them into the specified blob
        // NOTE returns 'null' if an error has taken place
        if (tBlob == null) return null;
        local r = read(addr, numBytes);
        if (r != null) tBlob.writeblob(r);
    }

    // ********** MB85RC PUBLIC NATIVE METHODS ***********
    // ***************************************************

    function isEnabled() {

        // Return the SPI FRAM's state: enabled (true) or not (false)
        return _enabled;
    }

    function clear(value = 0) {

        // Write a single value (default = 0) to the enture chip address space
        // Create a 1KB blob (auto-zero'd)
        local aBlob = blob(1024);

        if (value != 0) {
            // Fill blob with alternative 8-bit clear value
            if (value < 0x00 || value > 0xFF || (typeof value != "integer")) value = 0x00;
            for (local i = 0 ; i < 1024 ; i++) {
                aBlob[i] = value;
            }
        }

        for (local i = 0 ; i < (_size / 8) ; i++) {
            // Write the 1KB blob _size / 8 times to clear every byte in the chip
            aBlob.seek(0, 'b');
            local a = writeBlob(i * 1024, aBlob);
            if (a != 0) {
                server.error("MB85RC.clear() I2C write error");
                break;
            }
        }
    }

    function readByte(addr = 0) {

        // Read and return a single byte (as integer) from the FRAM
        // Returns imp API I2C error code if there was a read error
        if (addr < _minAddress || addr > _maxAddress) return -1;
        local a = _i2c.read(_i2cAddr, _msb(addr).tochar() + _lsb(addr).tochar(), 1);
        // 'a' is a string - return it as an integer value (or error)
        return a != null ? a[0] : _i2c.readerror();
    }

    function readBlob(addr = 0, numBytes = 1) {

        // Read and return a blob of bytes from the FRAM
        // Returns imp API I2C error code if there was a read error
        if (addr < _minAddress || addr > _maxAddress) return -1;
        if (numBytes < 1 || numBytes > _maxAddress) return -1;
        if (numBytes + addr > _maxAddress) numBytes = _maxAddress - addr + 1;
        local s = _i2c.read(_i2cAddr, _msb(addr).tochar() + _lsb(addr).tochar(), numBytes);
        if (s == null) return _i2c.readerror();
        local b = blob(s.len());
        b.writestring(s);
        return b;
    }

    function writeByte(addr = 0, byte = 0) {

        // Write a single byte to the FRAM; return the value from the I2C operation
        // Returns the imp API I2C error code or 0 for success
        if (addr < _minAddress || addr > _maxAddress) return -1;
        if (byte < 0x00 || byte > 0xFF) return -1;
        return _i2c.write(_i2cAddr, _msb(addr).tochar() + _lsb(addr).tochar() + byte.tochar());
    }

    function writeBlob(addr = 0, data = null, wrap = false) {

        // Write a blob of bytes to the FRAM
        // Returns the imp API I2C error code or 0 for success
        if (addr < _minAddress || addr > _maxAddress) return -1;
        if (data == null || data.len() == 0) return -1;
        if (data.len() + addr > _maxAddress && !wrap) data.resize(_maxAddress - addr);
        return _i2c.write(_i2cAddr, _msb(addr).tochar() + _lsb(addr).tochar() + data.tostring());
    }

    function setWriteProtectPin(writeProPin = null, startState = 0) {

        // Specify which imp pin is being used to control the FRAM write-protect pin
        // Set 'startState' to 1 for write protection, 0 for no write protection
        // NOTE this can also be set with the constructor
        // Returns true to indicate success, otherwise false
        if (writeProPin == null || !("getdelay" in writeProPin)) {
            // Caller must add a non-null pin - and it must be an imp pin (hence 'getdelay' check)
            server.error("MB85RC.setWriteProtectPin() no write-protect pin specified");
            return false;
        }

        if (startState != 0 && startState != 1) {
            // Caller must specify a valid initial pin state
            server.error("MB85RC.setWriteProtectPin() invalid write-protect pin state specified");
            return false;
        }

        _wPin = writeProPin;
        _wPinState = startState;
        _wPin.configure(DIGITAL_OUT, _wPinState);
        return true;
    }

    function setWriteProtect(state = 0) {

        // Specify the state of the FRAM write-protect pin
        // Set 'state' to 1 for write protection, 0 for no write protection
        // Returns true to indicate success, otherwise false
        if (_wPin == null) {
            // Caller must have already specified a valid write-protect pin
            server.error("MB85RC.setWriteProtect() no write protect pin yet set");
            return false;
        }

        if (typeof state == "bool") state = state == true ? 1 : 0;
        if (typeof state != "integer") state = 0;
        if (state != _wPinState) {
            _wPin.write(state);
            _wPinState = state;
        }

        return true;
    }

    function maxAddress() {

        // Return the FRAM chip's upper address
        return _maxAddress - 1;
    }

    function csize() {

        // Return the FRAM chip's size in Kbits
        return _size;
    }

    function checkFramInfo() {

        // Return FRAM chip information
        local bytes = _i2c.read(MB85RC_CHIP_INFO_OPCODE, _i2cAddr.tochar(), 3);
        if (bytes == null) return false;
        local manufID = (bytes[0] << 4) + (bytes[1]  >> 4);
        local prodID = ((bytes[1] & 0x0F) << 8) + bytes[2];
        if (manufID != 0x00A) {
            if (_debug) server.error("Unexpected Manufacturer ID: 0x" + manufID + " for chip at I2C address: " + format("0x%02X", _i2cAddr));
            return false;
        }

        if (prodID != 0x510) {
            if (_debug) server.error("Unexpected Product ID: 0x" + prodID + " for chip at I2C address: " + format("0x%02X", _i2cAddr));
            return false;
        }

        if (_debug) {
            server.log("FRAM I2C Address: " + format("0x%02X", _i2cAddr));
            server.log(" Manufacturer ID: " + format("0x%02X", manufID));
            server.log("      Product ID: " + format("0x%02X", prodID));
            server.log("            Size: " + _size + "Kb (" + (_size / 8) + "KB)");
            server.log("   Address Range: " + format("0x%04X", _minAddress) + "-" + format("0x%04X", _maxAddress - 1));
        }

        return true;
    }

    // ********** PRIVATE FUNCTIONS (DO NOT CALL) **********
    // *****************************************************

    function _lsb(address) {

        // Return a 16-bit address' least-significant byte
        return address & 0xFF;
    }

    function _msb(address) {

        // Return a 16-bit address' most-significant byte
        return (address >> 8) & 0xFF;
    }
}
