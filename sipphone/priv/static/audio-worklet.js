// Runs on the audio thread.
//  - microphone (context rate) -> 8 kHz s16le frames of 160 samples (20 ms) -> main thread
//  - 8 kHz s16le PCM from the main thread -> jitter buffer -> speakers (context rate)
class PhoneProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ratio = sampleRate / 8000;
    this.phase = 0;
    this.acc = 0;
    this.n = 0;
    this.out = new Int16Array(160);
    this.o = 0;

    this.N = 16000;
    this.ring = new Float32Array(this.N);
    this.r = 0;
    this.w = 0;
    this.count = 0;
    this.frac = 0;
    this.step = 8000 / sampleRate;
    this.playing = false;

    this.port.onmessage = (e) => this.enqueue(new Int16Array(e.data));
  }

  enqueue(pcm) {
    for (let i = 0; i < pcm.length; i++) {
      if (this.count >= this.N - 1) { this.r = (this.r + 1) % this.N; this.count--; }
      this.ring[this.w] = pcm[i] / 32768;
      this.w = (this.w + 1) % this.N;
      this.count++;
    }
    const max = 3200; // keep latency under 400 ms
    if (this.count > max) {
      this.r = (this.r + (this.count - max)) % this.N;
      this.count = max;
    }
  }

  process(inputs, outputs) {
    const inp = inputs[0] && inputs[0][0];
    if (inp) {
      for (let i = 0; i < inp.length; i++) {
        this.acc += inp[i];
        this.n++;
        this.phase += 1;
        if (this.phase >= this.ratio) {
          this.phase -= this.ratio;
          let v = this.acc / this.n;
          this.acc = 0;
          this.n = 0;
          v = Math.max(-1, Math.min(1, v));
          this.out[this.o++] = (v * 32767) | 0;
          if (this.o === 160) {
            this.port.postMessage(this.out.buffer, [this.out.buffer]);
            this.out = new Int16Array(160);
            this.o = 0;
          }
        }
      }
    }

    const out = outputs[0][0];
    for (let i = 0; i < out.length; i++) {
      if (!this.playing && this.count >= 480) this.playing = true; // 60 ms pre-buffer
      if (this.playing && this.count >= 2) {
        const a = this.ring[this.r];
        const b = this.ring[(this.r + 1) % this.N];
        out[i] = a + (b - a) * this.frac;
        this.frac += this.step;
        while (this.frac >= 1) {
          this.frac -= 1;
          this.r = (this.r + 1) % this.N;
          this.count--;
        }
      } else {
        out[i] = 0;
        this.playing = false;
      }
    }
    return true;
  }
}

registerProcessor('phone-processor', PhoneProcessor);
