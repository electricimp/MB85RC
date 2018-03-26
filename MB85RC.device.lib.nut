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


const MB85RC_SPIFLASH_PREVERIFY = 2;
const MB85RC_SPIFLASH_POSTVERIFY = 1;
const MB85RC_SPIFLASH_NOERROR = 0;

class MB85RC {

    // Represents a single Fujitsu MB85RC FRAM chip
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
        if (i2cBus == null) throw "Null I2C bus passed to MB85RC constructor";

        if (writeProtectPin != null) {
            // A write-protect pin has been passed; configure it to low – write-permitted
            _wPin = writeProtectPin;
            _wPinState = 0;
            _wPin.configure(DIGITAL_OUT, _wPinState);
        }

        // Check that the 'size' parameter's argument is a permitted size (in KB)
        local sizes = [4, 16, 64, 256, 512, 1024];
        local sFlag = false;
        foreach (aSize in sizes) {
            if (size == aSize) {
                _maxAddress = (size / 8) * 1024;
                _size = size;
                sFlag = true;
            }
        }

        // Unavailable size supplied - throw a runtime error
        if (!sFlag) throw ("MB85RC mis-sized in constructor: " + size / 8 + "KB");

        // Set the object properties
        _i2c = i2cBus;
        _i2cAddr = i2cAddress;
        _debug = debug;
        _enabled = true;

        // Check that we have an MB85RC chip connected. Throw a runtime error if not
        if (!checkFramInfo()) throw format("No MB85RC found at I2C address 0x%02X", i2cAddress);
    }

    // The following methods match those offered by the imp API
    // hardware.spiflash object

    function enable() {
        _enabled = true;
    }

    function disable() {
        _enabled = false;
    }

    function isenabled() {
        return _enabled;
    }

    function erasesector(boundAddr = 0) {
        if (!_enabled) {
            // The code is trying to work with a disabled MB85RC,
            // so just issue a warning to allow the host app to recover
            server.error("FRAM must enabled to erase a sector");
            return null;
        }

        if (boundAddr % 4096 != 0) {
            // The code is trying to erase across 4KB boundaries,
            // so just issue a warning to allow the host app to recover
            server.error("FRAM sector to erase must be on 4KB boundary");
            return;
        }

        if (boundAddr >= _maxAddress || boundAddr < 0) {
            // The code is trying to erase beyond its size,
            // so just issue a warning to allow the host app to recover
            server.error("FRAM sector to erase out of range");
            return;
        }

        for (local i = boundAddr ; i < boundAddr + 4096 ; i++) {
            if (i < _maxAddress) writeByte(i, 0x00);
        }
    }

    function chipid () {
        return _i2cAddr;
    }

    function size() {
        return ((_size / 8) * 1024);
    }

    function write(addr = -1, source = null, flags = 0, start = -1, end = -1) {

        // Writes a blob into the MB85RV at the specified address

        if (!_enabled) {
            // The code is trying to work with a disabled MB85RC,
            // so just issue a warning to allow the host app to recover
            server.error("FRAM must be enabled to write");
            return null;
        }

        if (addr < 0 || addr >= _maxAddress) {
            // The code is trying to write beyond its size,
            // so just issue a warning to allow the host app to recover
            server.error("FRAM write out of range");
            return (flags != MB85RC_SPIFLASH_NOERROR ? MB85RC_SPIFLASH_PREVERIFY : MB85RC_SPIFLASH_NOERROR);
        }

        if (source == null) {
            // The code is trying to write without specifying a data source,
            // so just issue a warning to allow the host app to recover
            server.error("FRAM write null data source");
            return (flags != MB85RC_SPIFLASH_NOERROR ? MB85RC_SPIFLASH_PREVERIFY : MB85RC_SPIFLASH_NOERROR);
        }

        if (start < 0 || start >= source.len()) start = 0;
        if (end > source.len() || end < 0) end = source.len();
        if (start == end) {
            if (start < source.len()) {
                end = start + 1;
            } else {
                start = end - 1;
            }
        } else if (start > end) {
            local a = end;
            end = start;
            start = a;
        }

        source.seek(start, 'b');
        local b = source.readblob(end - start);
        local r = writeBlob(addr, b);

        if (r == -1) {
            server.error("FRAM write I2C error");
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

        if (!_enabled) {
            // The code is trying to write without specifying a data source,
            // so just issue a warning to allow the host app to recover
            server.error("FRAM must be enabled to read");
            return null;
        }

        if (addr < 0 || addr >= _maxAddress) {
            // The code is trying to read beyond its size,
            // so just issue a warning to allow the host app to recover
            server.error("FRAM read out of range");
            return null;
        }

        if (_maxAddress - addr < numBytes) numBytes = _maxAddress - addr;
        local r = readBlob(addr, numBytes);
        return (r == -1 ? null : r);
    }

    function readintoblob(addr = 0, tBlob = null, numBytes = 1) {

        if (tBlob == null) return null;
        local r = read(addr, numBytes);
        if (r != null) tBlob.writeblob(r);
    }

    // MB85RC native methods

    function clear(value = 0) {
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
            if (a == -1) break;
        }
    }

    function readByte(addr = 0) {
        if (addr >= _maxAddress || addr < _minAddress) return -1;
        return _i2c.read(_i2cAddr, _msb(addr).tochar() + _lsb(addr).tochar(), 1);
    }

    function writeByte(addr = 0, byte = 0) {
        if (addr >= _maxAddress || addr < _minAddress) return -1;
        if (byte < 0 || byte > 0xFF) return -1;
        return _i2c.write(_i2cAddr, _msb(addr).tochar() + _lsb(addr).tochar() + byte.tochar());
    }

    function writeBlob(addr = 0, data = null, wrap = false) {
        if (addr >= _maxAddress || addr < _minAddress) return -1;
        if (data == null) return -1;
        if (data.len() + addr > _maxAddress) {
            if (!wrap) data.resize(_maxAddress - addr);
        }

        return _i2c.write(_i2cAddr, _msb(addr).tochar() + _lsb(addr).tochar() + data.tostring());
    }

    function readBlob(addr = 0, numBytes = 1) {
        if (addr >= _maxAddress || addr < _minAddress) return -1;
        if (numBytes < 1 || numBytes >= _maxAddress) return -1;
        local s = _i2c.read(_i2cAddr, _msb(addr).tochar() + _lsb(addr).tochar(), numBytes);
        local b = blob(s.len());
        b.writestring(s);
        return b;
    }

    function setWriteProtectPin(writeProPin = null, startState = 0) {
        if (writeProPin == null) {
            // Caller must add a non-null pin
            server.error("No write-protect pin specified in MB85RC.setWriteProtect()");
            return false;
        }

        if (startState != 0 && startState != 1) {
            // Caller must specify a valid state
            server.error("No write-protect pin state specified in MB85RC.setWriteProtect()");
            return false;
        }

        _wPin = writeProPin;
        _wPinState = startState;
        _wPin.configure(DIGITAL_OUT, _wPinState);
        return true;
    }

    function setWriteProtect(state) {
        if (_wPin == null) {
            // Caller must specify a valid write-protect pin
            server.error("No write protect pin specified in MB85RC.setWriteProtect()");
            return false;
        }

        if (typeof state == "bool") state = state == true ? 1 : 0;
        if (state != _wPinState) {
            _wPin.write(state);
            _wPinState = state;
        }

        return true;
    }

    function maxAddress() {
        return _maxAddress;
    }

    function csize() {
        return _size;
    }

    function checkFramInfo() {
        local bytes = _i2c.read(0xF8, _i2cAddr.tochar(), 3);
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

    // PRIVATE FUNCTIONS

    function _lsb(address) {
        return address & 0xFF;
    }

    function _msb(address) {
        return (address >> 8) & 0xFF;
    }
}
