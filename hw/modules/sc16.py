"""sc16 helpers shared by the module reference models: a sample is the 32-bit
word {Q[31:16], I[15:0]}, each half signed 16 bit."""
import numpy as np


def unpack(words):
    w = np.asarray(words, np.uint32)
    i = (w & 0xFFFF).astype(np.uint16).view(np.int16).astype(np.int64)
    q = (w >> 16).astype(np.uint16).view(np.int16).astype(np.int64)
    return i, q


def pack(i, q):
    return ((np.asarray(q, np.int64) & 0xFFFF) << 16 | (np.asarray(i, np.int64) & 0xFFFF)).astype(np.uint32)


def sat16(v):
    return np.clip(v, -32768, 32767)


def to_complex(words):
    i, q = unpack(words)
    return (i + 1j * q).astype(np.complex64) / 32768


def _round(v):
    """to the nearest integer, halves away from zero (as C lround, used by the
    Soapy module's CF32 -> CS16 conversion)"""
    return (np.sign(v) * np.floor(np.abs(v) + 0.5)).astype(np.int64)


def from_complex(x):
    """complex samples (full scale 1.0) to words, rounded and saturated"""
    x = np.asarray(x, np.complex128)
    return pack(sat16(_round(x.real * 32768)), sat16(_round(x.imag * 32768)))
