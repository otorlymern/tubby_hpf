Engine_TubbyHPF : CroneEngine {
  var <>synth;

  *new { |ctx, done| ^super.new(ctx, done) }

  alloc { |context, done|
    SynthDef(\tubby_hpf, { |inL, inR, out, cutoff=70, drive=0.0, outlevel=1.0, mode=0, bypass=0, stepclick=0|
      // declare ALL locals up front
      var dry, sig, pre, rq_bump=0.55, rq_tub=0.85, click, lin, wet, outsig, drive_lin;

      dry = [In.ar(inL), In.ar(inR)];

      // tiny transient on step changes; trigger on value changes
      click = Decay2.ar(Changed.kr(stepclick), 0.0005, 0.005) * (WhiteNoise.ar * 0.004);

      // input "console-ish" saturation: pre-gain into soft clip
      // drive in dB: -6..+24 mapped outside, clipped here for safety
      drive_lin = drive.clip(-24, 36);
      lin = dry * (10.pow(drive_lin/20));
      pre = tanh(lin + (lin * 0.15)); // slight asymmetry and soft knee

      // choose ladder based on mode 0..2
      sig = SelectX.ar(mode.clip(0, 2), [
        // FLAT (0): 3x HPF
        HPF.ar(HPF.ar(HPF.ar(pre, cutoff), cutoff), cutoff),
        // BUMP (1): 2x resonant + 1x HPF
        HPF.ar(RHPF.ar(RHPF.ar(pre, cutoff, rq_bump), cutoff, rq_bump), cutoff),
        // TUB (2): 3x resonant with higher Q
        RHPF.ar(RHPF.ar(RHPF.ar(pre, cutoff, rq_tub), cutoff, rq_tub), cutoff, rq_tub)
      ]);

      // add a whisper of click when changing steps
      sig = sig + click;

      // output stage
      wet = sig * outlevel;
      outsig = (bypass > 0.5).if(dry * outlevel, wet); // bypass skips drive + filter
      Out.ar(out, outsig);
    }).add;

    this.synth = Synth(\tubby_hpf, [
      \inL, context.in_b[0].index, \inR, context.in_b[1].index,
      \out, context.out_b.index,
      \cutoff, 70, \drive, 0.0, \outlevel, 1.0,
      \mode, 0, \bypass, 0, \stepclick, 0
    ], context.xg);

    // Lua -> SC hooks
    this.addCommand("cutoff","f",{ |msg| synth.set(\cutoff, msg[1]) });
    this.addCommand("drive","f",{ |msg| synth.set(\drive, msg[1]) });
    this.addCommand("outlevel","f",{ |msg| synth.set(\outlevel, msg[1]) });
    this.addCommand("mode","i",{ |msg| synth.set(\mode, msg[1]) });
    this.addCommand("bypass","i",{ |msg| synth.set(\bypass, msg[1]) });
    this.addCommand("click","i",{ |msg| synth.set(\stepclick, msg[1]) }); // triggers on value changes

    context.server.sync; // ensure definitions are ready before notifying Lua
    done.value(this);
  }

  free {
    synth.free;
    synth = nil;
  }
}
