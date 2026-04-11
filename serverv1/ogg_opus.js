/**
 * Minimal OGG-Opus container writer for streaming.
 * Wraps raw Opus frames into OGG pages that Google STT can consume.
 */

// OGG CRC-32 lookup table (polynomial 0x04C11DB7)
const crcTable = new Int32Array(256);
(function initCRC() {
  for (let i = 0; i < 256; i++) {
    let r = i << 24;
    for (let j = 0; j < 8; j++) {
      r = (r & 0x80000000) ? ((r << 1) ^ 0x04C11DB7) : (r << 1);
    }
    crcTable[i] = r;
  }
})();

function oggCRC(data) {
  let crc = 0;
  for (let i = 0; i < data.length; i++) {
    crc = (crc << 8) ^ crcTable[((crc >>> 24) ^ data[i]) & 0xFF];
  }
  return crc >>> 0; // unsigned
}

function buildOggPage(headerType, granulePos, serialNo, pageSeqNo, payload) {
  // Segment table: split payload into 255-byte segments
  const segments = [];
  let remaining = payload.length;
  while (remaining >= 255) {
    segments.push(255);
    remaining -= 255;
  }
  segments.push(remaining); // last segment (or 0 if exact multiple)

  const headerSize = 27 + segments.length;
  const page = Buffer.alloc(headerSize + payload.length);

  // Capture pattern
  page.write('OggS', 0);
  // Version
  page[4] = 0;
  // Header type
  page[5] = headerType;
  // Granule position (8 bytes LE) - use BigInt for safety
  const gp = BigInt(granulePos);
  page.writeBigInt64LE(gp, 6);
  // Serial number
  page.writeUInt32LE(serialNo, 14);
  // Page sequence number
  page.writeUInt32LE(pageSeqNo, 18);
  // CRC placeholder (set to 0 for calculation)
  page.writeUInt32LE(0, 22);
  // Number of segments
  page[26] = segments.length;
  // Segment table
  for (let i = 0; i < segments.length; i++) {
    page[27 + i] = segments[i];
  }
  // Payload
  payload.copy(page, headerSize);

  // Calculate and set CRC
  const crc = oggCRC(page);
  page.writeUInt32LE(crc, 22);

  return page;
}

class OggOpusWriter {
  constructor(sampleRate = 16000, channels = 1) {
    this.sampleRate = sampleRate;
    this.channels = channels;
    this.serialNo = (Math.random() * 0xFFFFFFFF) >>> 0;
    this.pageSeqNo = 0;
    this.granulePos = 0;
    this.frameSamples = 320; // 20ms @ 16kHz
  }

  /**
   * Returns the OGG header pages (OpusHead + OpusTags).
   * Must be sent as the first audio data to Google STT.
   */
  getHeaders() {
    // OpusHead (19 bytes)
    const head = Buffer.alloc(19);
    head.write('OpusHead', 0);
    head[8] = 1; // version
    head[9] = this.channels;
    head.writeUInt16LE(3840, 10); // pre-skip
    head.writeUInt32LE(this.sampleRate, 12); // input sample rate
    head.writeInt16LE(0, 16); // output gain
    head[18] = 0; // mapping family

    const headPage = buildOggPage(0x02, 0, this.serialNo, this.pageSeqNo++, head);

    // OpusTags
    const vendor = 'node';
    const tags = Buffer.alloc(8 + 4 + vendor.length + 4);
    tags.write('OpusTags', 0);
    tags.writeUInt32LE(vendor.length, 8);
    tags.write(vendor, 12);
    tags.writeUInt32LE(0, 12 + vendor.length); // no comments

    const tagsPage = buildOggPage(0x00, 0, this.serialNo, this.pageSeqNo++, tags);

    return Buffer.concat([headPage, tagsPage]);
  }

  /**
   * Wraps a single raw Opus frame into an OGG page.
   */
  wrapFrame(opusFrame) {
    this.granulePos += this.frameSamples;
    const page = buildOggPage(
      0x00,
      this.granulePos,
      this.serialNo,
      this.pageSeqNo++,
      Buffer.from(opusFrame)
    );
    return page;
  }
}

module.exports = { OggOpusWriter };
