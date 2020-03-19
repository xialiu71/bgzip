import io
import zlib
import struct
from math import ceil

from libc.stdlib cimport abort
from cython.parallel import prange

from czlib cimport *
from cpython_nogil cimport *


cdef enum:
    NUMBER_OF_BLOCKS = 20000
    MAGIC_LENGTH = 4
    BGZIP_OK = 0
    BGZIP_INSUFFICIENT_BYTES = -1


cdef const unsigned char * MAGIC = "\037\213\010\4"
# cdef Bytef * HEADER = b"\037\213\010\4\0\0\0\0\0\377\6\0\102\103\2\0"
cdef bytes HEADER = b"\037\213\010\4\0\0\0\0\0\377\6\0\102\103\2\0"


ctypedef block_header_s BlockHeader
cdef struct block_header_s:
    unsigned char magic[MAGIC_LENGTH]
    unsigned int mod_time
    unsigned char extra_flags
    unsigned char os_type
    unsigned short extra_len


ctypedef block_header_subfield_s BlockHeaderSubfield
cdef struct block_header_subfield_s:
    unsigned char id_[2]
    unsigned short length


ctypedef block_header_bgzip_subfield_s BlockHeaderBGZipSubfield
cdef struct block_header_bgzip_subfield_s:
    unsigned char id_[2]
    unsigned short length
    unsigned short block_size


ctypedef block_tailer_s BlockTailer
cdef struct block_tailer_s:
    unsigned int crc
    unsigned int inflated_size


ctypedef block_s Block
cdef struct block_s:
    unsigned int deflated_size
    unsigned int inflated_size
    unsigned int crc
    unsigned short block_size
    Bytef * next_in
    unsigned int available_in
    Bytef * next_out
    unsigned int avail_out


ctypedef bgzip_stream_s BGZipStream
cdef struct bgzip_stream_s:
    unsigned int available_in
    Bytef *next_in


cdef void c_exception(const char * reason) nogil:
    with gil:
        print(reason)
        abort()


cdef void inflate_block(Block * block) nogil:
    cdef z_stream zst
    cdef int err

    zst.zalloc = NULL
    zst.zfree = NULL
    zst.opaque = NULL
    zst.avail_in = block.deflated_size
    zst.avail_out = 1024 * 1024
    zst.next_in = block.next_in
    zst.next_out = block.next_out

    err = inflateInit2(&zst, -15)
    if Z_OK != err:
        c_exception("Failed to initialize zlib compression")
    err = inflate(&zst, Z_FINISH)
    if Z_STREAM_END == err:
        pass
    else:
        c_exception("Compression error encountered")
    inflateEnd(&zst)

    if block[0].inflated_size != zst.total_out:
        c_exception("Block differently sized than expected")

    if block.crc != crc32(0, block.next_out, block.inflated_size):
        c_exception("crc32 mismatch!")

    # Difference betwwen `compress` and `deflate`:
    # https://stackoverflow.com/questions/10166122/zlib-differences-between-the-deflate-and-compress-functions


cdef void * ref_and_advance(BGZipStream * rb, unsigned int member_size, int *err) nogil:
    if rb.available_in  < member_size:
        err[0] = BGZIP_INSUFFICIENT_BYTES
        return NULL
    else:
        ret_val = rb.next_in
        rb.next_in += member_size
        rb.available_in  -= member_size
        err[0] = BGZIP_OK
        return ret_val


cdef int read_block(Block * block, BGZipStream *src) nogil:
    cdef unsigned int i
    cdef int err
    cdef BlockHeader * head
    cdef BlockTailer * tail
    cdef BlockHeaderSubfield * subfield
    cdef Bytef * subfield_data
    cdef unsigned int extra_len

    block.block_size = 0

    head = <BlockHeader *>ref_and_advance(src, sizeof(BlockHeader), &err)
    if err:
        return err

    for i in range(<unsigned int>MAGIC_LENGTH):
        if head.magic[i] != MAGIC[i]:
            c_exception("Magic not found in gzip header")

    extra_len = head.extra_len
    while extra_len > 0:
        subfield = <BlockHeaderSubfield *>ref_and_advance(src, sizeof(BlockHeaderSubfield), &err)
        if err:
            return err
        extra_len -= sizeof(BlockHeaderSubfield)

        subfield_data = <Bytef *>ref_and_advance(src, subfield.length, &err)
        if err:
            return err
        extra_len -= sizeof(subfield.length)

        if b"B" == subfield.id_[0] and b"C" == subfield.id_[1]:
            if subfield.length != 2:
                c_exception("Unexpected subfield length in gzip header")
            block.block_size = (<unsigned short *>subfield_data)[0]

    if 0 != extra_len:
        c_exception("Unexpected header length")

    if 0 >= block.block_size:
        c_exception("Negative or missing block size.")

    block.next_in = src.next_in
    block.deflated_size = 1 + block.block_size - sizeof(BlockHeader) - head.extra_len - sizeof(BlockTailer)

    ref_and_advance(src, block.deflated_size, &err)
    if err:
        return err

    tail = <BlockTailer *>ref_and_advance(src, sizeof(BlockTailer), &err)
    if err:
        return err

    block.crc = tail.crc
    block.inflated_size = tail.inflated_size


def decompress_into(bytes src_buff, bytearray dst_buff, int num_threads):
    """
    Inflate bytes from `src_buff` into `dst_buff`, resizing `dst_buff` as needed.
    """
    cdef int i
    cdef PyObject * dst = <PyObject *>dst_buff
    cdef Bytef * out = NULL
    cdef unsigned int offset = len(dst_buff)
    cdef int bytes_read = 0, inflated_size = 0
    cdef int number_of_blocks = 0
    cdef Block blocks[NUMBER_OF_BLOCKS]

    cdef BGZipStream src
    src.next_in = src_buff
    src.available_in  = len(src_buff)

    with nogil:
        for i in range(NUMBER_OF_BLOCKS):
            if BGZIP_INSUFFICIENT_BYTES == read_block(&blocks[i], &src):
                break
            bytes_read += 1 + blocks[i].block_size
            inflated_size += blocks[i].inflated_size
            number_of_blocks += 1

    PyByteArray_Resize(dst, offset + inflated_size)
    out = <Bytef *>PyByteArray_AS_STRING(dst)
    out += offset

    with nogil:
        for i in range(number_of_blocks):
            blocks[i].next_out = out
            out += blocks[i].inflated_size

        for i in prange(number_of_blocks, num_threads=num_threads, schedule="dynamic"):
            inflate_block(&blocks[i])

    return bytes_read


def decompress_into_2(bytes src_buff, object dst_buff_obj, unsigned int offset, int num_threads):
    """
    Inflate bytes from `src_buff` into `dst_buff`
    """
    cdef int i
    cdef Bytef * out = NULL
    cdef unsigned int bytes_read = 0, bytes_inflated = 0
    cdef int number_of_blocks = 0
    cdef Block blocks[NUMBER_OF_BLOCKS]

    cdef BGZipStream src
    src.next_in = src_buff
    src.available_in = len(src_buff)

    cdef PyObject * dst_buff = <PyObject *>dst_buff_obj
    if PyMemoryView_Check(dst_buff):
        # TODO: Check buffer is contiguous, has normal stride
        out  = <Bytef *>(<Py_buffer *>PyMemoryView_GET_BUFFER(dst_buff)).buf
        assert NULL != out
    else:
        raise Exception("dst_buff_obj must be a memoryview instance.")
        # TODO: support bytearray objects

    cdef unsigned int avail_out = PySequence_Size(dst_buff) - offset
    out += offset

    with nogil:
        for i in range(NUMBER_OF_BLOCKS):
            if BGZIP_INSUFFICIENT_BYTES == read_block(&blocks[i], &src):
                break
            if avail_out < bytes_inflated + blocks[i].inflated_size:
                break
            bytes_read += 1 + blocks[i].block_size
            bytes_inflated += blocks[i].inflated_size
            number_of_blocks += 1

        for i in range(number_of_blocks):
            blocks[i].next_out = out
            out += blocks[i].inflated_size

        for i in prange(number_of_blocks, num_threads=num_threads, schedule="dynamic"):
            inflate_block(&blocks[i])

    return bytes_read, bytes_inflated


cdef void compress_block(Block * block) nogil:
    cdef z_stream zst
    cdef int err = 0
    cdef BlockHeader * head
    cdef BlockHeaderBGZipSubfield * head_subfield
    cdef BlockTailer * tail
    cdef int wbits = -15
    cdef int mem_level = 8

    head = <BlockHeader *>block.next_out
    block.next_out += sizeof(BlockHeader)

    head_subfield = <BlockHeaderBGZipSubfield *>block.next_out
    block.next_out += sizeof(BlockHeaderBGZipSubfield)

    zst.zalloc = NULL
    zst.zfree = NULL
    zst.opaque = NULL
    zst.next_in = block.next_in
    zst.avail_in = block.available_in
    zst.next_out = block.next_out
    zst.avail_out = 1024 * 1024
    err = deflateInit2(&zst, Z_BEST_COMPRESSION, Z_DEFLATED, wbits, mem_level, Z_DEFAULT_STRATEGY)
    if Z_OK != err:
        c_exception("Failed to initialize zlib compression")
    err = deflate(&zst, Z_FINISH)
    if Z_STREAM_END != err:
        c_exception("Compression error encountered")
    deflateEnd(&zst)

    block.next_out += zst.total_out

    tail = <BlockTailer *>block.next_out

    for i in range(MAGIC_LENGTH):
        head.magic[i] = MAGIC[i]
    head.mod_time = 0
    head.extra_flags = 0
    head.os_type = b"\377"
    head.extra_len = sizeof(BlockHeaderBGZipSubfield)

    head_subfield.id_[0] = b"B"
    head_subfield.id_[1] = b"C"
    head_subfield.length = 2
    head_subfield.block_size = sizeof(BlockHeader) + sizeof(BlockHeaderBGZipSubfield) + zst.total_out + sizeof(BlockTailer) - 1

    tail.crc = crc32(0, block.next_in, block.inflated_size)
    tail.inflated_size = block.inflated_size

    block.block_size = 1 + head_subfield.block_size


cdef unsigned int _block_inflated_size = 65280
cdef unsigned int _block_metadata_size = sizeof(BlockHeader) + sizeof(BlockHeaderBGZipSubfield) + sizeof(BlockTailer)
block_inflated_size = _block_inflated_size
block_metadata_size = _block_metadata_size


def compress_chunks(input_chunks, int num_threads):
    cdef int i, chunk_size, compressed_chunk_guess_size
    cdef int number_of_chunks = len(input_chunks)
    cdef Block blocks[NUMBER_OF_BLOCKS]

    if number_of_chunks > NUMBER_OF_BLOCKS:
        raise Exception(f"Cannot compress more than {NUMBER_OF_BLOCKS} chunks per call. Received {number_of_chunks}")

    cdef PyObject * chunk, * compressed_chunk
    cdef PyObject * chunks = <PyObject *>input_chunks
    cdef PyObject * compressed_chunks[NUMBER_OF_BLOCKS]

    for i in range(number_of_chunks):
        chunk = PyList_GetItem(chunks, i)
        chunk_size = PyBytes_GET_SIZE(chunk)
        compressed_chunk_guess_size = chunk_size + _block_metadata_size
        compressed_chunk = PyByteArray_FromStringAndSize(NULL, compressed_chunk_guess_size)
        compressed_chunks[i] = compressed_chunk

        blocks[i].inflated_size = chunk_size
        blocks[i].next_in = <Bytef *>PyBytes_AS_STRING(chunk)
        blocks[i].available_in = chunk_size
        blocks[i].next_out = <Bytef *>PyByteArray_AS_STRING(compressed_chunk)
        blocks[i].avail_out = compressed_chunk_guess_size

    with nogil:
        for i in prange(number_of_chunks, num_threads=num_threads, schedule="dynamic"):
            compress_block(&blocks[i])
            compressed_chunk = compressed_chunks[i]

    ret = list()
    for i in range(number_of_chunks):
        compressed_chunk = compressed_chunks[i]
        PyByteArray_Resize(compressed_chunk, blocks[i].block_size)
        ret.append(<bytearray>compressed_chunks[i])
        Py_DECREF(compressed_chunk)
    return ret


cdef void _get_buffer(PyObject * obj, Py_buffer * view):
    cdef int err

    err = PyObject_GetBuffer(obj, view, PyBUF_SIMPLE)
    if -1 == err:
        raise Exception()

def compress_to_stream(input_buff_obj, list scratch_buffers, handle, int num_threads):
    """
    Compress the data in `input_buff_obj` and write it to `handle`.

    `scratch_buffers` should contain enough buffers to hold the number of blocks compressed. Each
    buffer should hold `_block_inflated_size + _block_metadata_size` bytes.
    """
    cdef int i, chunk_size
    cdef unsigned int bytes_available = len(input_buff_obj)
    cdef int number_of_chunks = ceil(bytes_available / block_inflated_size)
    cdef Block blocks[NUMBER_OF_BLOCKS]

    if number_of_chunks > NUMBER_OF_BLOCKS:
        raise Exception(f"Cannot compress more than {NUMBER_OF_BLOCKS} chunks per call. Received {number_of_chunks}")

    cdef PyObject * compressed_chunks = <PyObject *>scratch_buffers
    cdef PyObject * compressed_chunk

    cdef Py_buffer input_view 
    _get_buffer(<PyObject *>input_buff_obj, &input_view)

    with nogil:
        for i in range(number_of_chunks):
            compressed_chunk = <PyObject *>PyList_GetItem(compressed_chunks, i)

            if bytes_available >= _block_inflated_size:
                chunk_size = _block_inflated_size
            else:
                chunk_size = bytes_available

            bytes_available -= _block_inflated_size

            blocks[i].inflated_size = chunk_size
            blocks[i].next_in = <Bytef *>input_view.buf + (i * _block_inflated_size)
            blocks[i].available_in = chunk_size
            blocks[i].next_out = <Bytef *>PyByteArray_AS_STRING(compressed_chunk)
            blocks[i].avail_out = _block_inflated_size + _block_metadata_size

        for i in prange(number_of_chunks, num_threads=num_threads, schedule="dynamic"):
            compress_block(&blocks[i])

    PyBuffer_Release(&input_view)

    for i in range(number_of_chunks):
        handle.write(scratch_buffers[i][:blocks[i].block_size])