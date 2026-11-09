# Instrument files

Every instrument the engine has is defined here. None are in the code. Every `.inst` file in this folder is read when a tool or the baker starts, and again when you press F5 in the music editor, so a sound can be changed and heard without a rebuild.

| File | What's in it |
| --- | --- |
| `classic.inst` | The eleven voices that used to be hardcoded in the synth: sine, square, saw, bell, noise, piano, organ, strings, flute, pluck, marimba. Every `.song` written before still plays. |
| `orchestra.inst` | Strings, woodwinds, brass, keyboards, percussion, the three NES channels, and a choir. |

A game can add its own, in `<game>/assets/instruments/`. Those are read after these, so they win. A file whose name starts with `_` is skipped, which is an easy way to switch one off.

## The format

One block per instrument:

```text
instrument bugle                 # the key a song asks for: "track a bugle"
based_on trumpet                 # optional: start from another instrument
name "Bugle"
family brass                     # free text; the picker groups by it
range G4 G5                      # sounding, low then high: names or MIDI numbers
wave pulse 0.5                   # pulse <duty> | triangle | nes_triangle | saw | sine | noise | white | string
layer triangle 0.3 12            # second oscillator: <wave> <mix 0..1> <semitones up>
                                 # or "layer none"
envelope 0.02 0.1 0.8 0.06       # attack decay sustain release, in seconds
                                 # (sustain is a level; 0 means struck or plucked)
vibrato 5 0.1 0.2                # rate Hz, depth semitones, delay seconds
sweep -0.5 0.03                  # starts this many semitones off, glides home
breath 0.02                      # white noise mixed in
tone 0.7                         # low-pass: 1 is open, lower is darker
metallic 0                       # noise only: the NES "short" mode, clangy
gain 0.5
pan 0.2                          # -1 left .. 1 right, added to the track's
color 255 200 80                 # its colour in the music editor
end
```

And, optional, for more than a chip can do (see the music section of `nengine/README.md`):

```text
layer3 sine 0.1 24               # a third oscillator
layer_envelope 0.001 0.6 0 0.2   # the second oscillator's own envelope (layer3_envelope: the third's)
filter 1200 0.3                  # a two-pole low-pass, Hz and resonance; without it `tone` filters
keytrack 0.5                     # the cutoff follows the pitch
filter_env 0.05 0.4 1.5          # attack, decay, octaves: the cutoff opens and closes
vel_tone 1                       # octaves brighter per 100 of velocity
highpass 3000                    # Hz: the bottom off, for cymbals
click 0.3 0.02 0.5               # a noise burst at the start: level, decay, tone
string 0.5 0.6                   # wave string: damping, brightness of the pluck
```

Every line after the first is optional. A block starts from, in order:

1. its `based_on` instrument, if it names one — from any file, in any order;
2. otherwise whatever already has that key, from a file that sorts earlier — so a file of your own can change ONE thing and leave the rest alone:

   ```text
   instrument violin
   gain 0.4
   end
   ```

3. otherwise a plain square wave.

The same blocks can go inside a `.song`, so that song carries its own instruments and plays the same wherever it is opened. A song's own definition wins over a file with the same key, and saving the song flattens `based_on` into the full definition, so the sound survives changes to the orchestra.

## Why an instrument is more than a waveform

Consoles like the NES had a handful of tone generators, each putting out one simple repeating shape at a pitch you set. A violin and a trumpet can both be a sawtooth and still not sound alike, because everything that makes them different happens AROUND the oscillator:

| Line | What it does |
| --- | --- |
| `envelope` | How fast it speaks, falls, holds and dies. A harp is a sharp attack and no sustain; a horn swells in. |
| `vibrato` | A slow pitch wobble arriving a moment after the note. This is most of what makes a plain wave read as "violin" or "voice". |
| `sweep` | A fast slide at the start. A timpani is a triangle that drops. |
| `layer` | Two generators at once: an organ is a pulse plus the same pulse an octave up; a horn is a pulse softened with a triangle. |
| `tone` | A gentle low-pass, so a cello's saw is darker than a violin's. |

The pulse duty cycle is worth knowing: 0.5 is hollow and woody (clarinet-ish), 0.25 is brighter (oboe, trumpet), 0.125 is thin and nasal.

`string` is not an oscillator. It is a Karplus-Strong plucked string: a short loop, run round and round through a gentle low-pass, so the high frequencies die first and it starts bright and mellows. It is tuned to a fraction of a sample (an all-pass in the loop), and plucked from a triangle with a little noise, darker for a softer note. It sounds better than anything the oscillators can manage for a plucked note, so the harp and the pluck use it. It can only be the main wave, not a layer.

`triangle` is a clean triangle; `nes_triangle` is the NES's buzzy 16-step one (the chip `triangle_bass` uses it). `noise` is the NES shift register, which hisses brighter for a higher note; `white` is plain white noise whatever the note.
