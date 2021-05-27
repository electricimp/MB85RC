class MB85RC {
    // Represents a single Fujitsu MB85RC FRAM chip

    static VERSION = [1,0,0];

    static SPIFLASH_PREVERIFY = 2;
    static SPIFLASH_POSTVERIFY = 1;
    static SPIFLASH_NOERROR = 0;

    _i2c = null;
    _i2cAddr = null;
    _wPin = null;
    _wPinState = 0;
    _enabled = false;
    _debug = false;
    _minAddress = 0x0000;
    _maxAddress = 0x7FFF;
    _size = 256;
    _productID = 0;

    constructor (i2cBus = null, i2cAddress = 0xA0, size = 256, writeProtectPin = null, debug = false) {
        if (i2cBus == null) {
            throw("Null I2C bus passed to MB85RC constructor");
            return null;
        }

        if (writeProtectPin != null) {
            // A write-protect pin has been passed; configure it to low – write-permitted
            _wPin = writeProtectPin;
            _wPin.configure(DIGITAL_OUT, 0);
            _wPinState = 0;
        }

        local sizes = [4, 16, 64, 256, 512, 1024];
        local sFlag = false;
        foreach (cSize in sizes) {
            if (size == cSize) {
                _maxAddress = (size / 8) * 1024;
                _size = size;
                sFlag = true;
            }
        }

        switch(_size)
        {
            case 4 :
            _productID = 0x010;
            break;
            case 64 :
            _productID = 0x358;
            break;
            case 256 :
            _productID = 0x510;
            break;
            case 512 :
            _productID = 0x658;
            break;
            case 1024 :
            _productID = 0x758;
            break;
            default:
            server.log("Product ID not found for this size: " + size);
            _productID = 0;
        }

        if (!sFlag) {
            server.error("MB85RC mis-sized in constructor: " + size / 8 + "KB");
            return null;
        }

        _i2c = i2cBus;
        _i2cAddr = i2cAddress;
        _debug = debug;
        _enabled = true;
    }

    // hardware.spiflash() mirror methods - for compatibility

    function enable() {
        _enabled = true;
    }

    function disable() {
        _enabled = false;
    }

    function erasesector(boundAddr = 0) {
        if (!_enabled) {
            server.error("FRAM must not be disabled to erase a sector");
            return null;
        }

        if (boundAddr % 4096 != 0) {
            server.error("FRAM sector to erase must be on 4KB boundary");
            return;
        }

        if (boundAddr >= _maxAddress) {
            server.error("FRAM sector to erase out of range");
            return;
        }

        for (local i = boundAddr ; i < boundAddr + 4096 ; ++i) {
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
        if (!_enabled) {
            server.error("FRAM must not be disabled to write");
            return null;
        }

        // Writes a blob into the store
        if (addr < 0 || addr >= _maxAddress) {
            server.error("FRAM write out of range");
            if (flags != SPIFLASH_NOERROR) {
                return SPIFLASH_PREVERIFY;
            } else {
                return SPIFLASH_NOERROR;
            }
        }

        if (source == null) {
            server.error("FRAM write null data source");
            if (flags != SPIFLASH_NOERROR) {
                return SPIFLASH_PREVERIFY;
            } else {
                return SPIFLASH_NOERROR;
            }
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
            if (flags != SPIFLASH_NOERROR) {
                return SPIFLASH_POSTVERIFY;
            } else {
                return SPIFLASH_NOERROR;
            }
        }

        if (flags == SPIFLASH_POSTVERIFY) {
            // Do write verify
            local c = readBlob(addr, source.len());
            if (c == -1) return SPIFLASH_POSTVERIFY;

            for (local i = 0 ; i < b.len() ; ++i) {
                if (i < c.len()) {
                    if (c[i] != b[i]) {
                        if (flags != SPIFLASH_NOERROR) {
                            return SPIFLASH_POSTVERIFY;
                        } else {
                            return SPIFLASH_NOERROR;
                        }
                    }
                }
            }
        } else {
            return SPIFLASH_NOERROR;
        }

        return SPIFLASH_NOERROR;
    }

    function read(addr = 0, numBytes = 1) {
        if (!_enabled) {
            server.error("FRAM must not be disabled to read");
            return null;
        }

        local r = readBlob(addr, numBytes);
        if (r == -1) {
            return null;
        } else {
            return r;
        }
    }

    function readintoblob(addr = 0, tBlob = null, numBytes = 1) {
        if (!_enabled) {
            server.error("FRAM must not be disabled to read");
            return null;
        }

        if (tBlob == null) return null;
        local r = readBlob(addr, numBytes);
        if (r != -1) tBlob.writeblob(r);
    }

    // MB85RC methods

    function clear(value = 0) {
        // Create a 1KB blob (auto-zero'd)
        local aBlob = blob(1024);

        if (value !=0) {
            // Fill blob with alternative 8-bit clear value
            if (value < 0x00 || value > 0xFF || (typeof value != "integer")) value = 0x00;
            for (local i = 0 ; i < 1024 ; ++i) {
                aBlob[i] = value;
            }
        }

        for (local i = 0 ; i < (_size / 8) ; ++i) {
            // Write the 1KB blob _size times to clear every byte in the 32KB chip
            aBlob.seek(0, 'b');
            writeBlob(i * 1024, aBlob);
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
            // Got to add a non-null pin
            server.error("No write protect pin specified in setWriteProtect");
            return false;
        }

        if (startState != 0 && startState != 1) {
            // Got to specify a valid state
            server.error("No write protect pin state specified in setWriteProtect");
            return false;
        }

        _wPin = writeProPin;
        _wPinState = startState;
        _wPin.configure(DIGITAL_OUT, _wPinState);
        return true;
    }

    function setWriteProtect(state) {
        if (_wPin == null) {
            // Got to have a valid write-protect pin
            server.error("No write protect pin specified in setWriteProtect");
            return false;
        }

        if (typeof state = "bool") state = (state == true) ? 1:0;
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
        local manufID = (bytes[0] << 4) + (bytes[1]  >> 4);
        local prodID = ((bytes[1] & 0x0F) << 8) + bytes[2];
        if (manufID != 0x00A) {
            server.error("Unexpected Manufacturer ID: 0x" + manufID + " for chip at I2C address: " + format("0x%02X", _i2cAddr));
            return false;
        }

        if (prodID != _productID) {
            server.error("Unexpected Product ID: 0x" + prodID + " for chip at I2C address: " + format("0x%02X", _i2cAddr));
            return false;
        }

        if (_debug) {
            server.log("FRAM at I2C Address: " + format("0x%02X", _i2cAddr));
            server.log("    Manufacturer ID: " + format("0x%02X", manufID));
            server.log("         Product ID: " + format("0x%02X", prodID));
            server.log("               Size: " + _size + "Kb");
            server.log("      Address Range: " + format("0x%04X", _minAddress) + "-" + format("0x%04X", _maxAddress - 1));
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
