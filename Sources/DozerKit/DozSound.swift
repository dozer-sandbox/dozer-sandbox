import Foundation

// EXPERIMENTAL (604) — the audio sandbox's part of the tools layer: ALSA's command-line tools, an /etc/asound.conf
// whose `default` reaches the virtio card's playback AND capture devices (they are separate PCMs on this card, and
// ALSA's built-in default is device 0 — the capture device when both exist), and `doz-sound`, a TEMPORARY script
// to record and play through the Mac's microphone and speakers. POSIX sh + busybox/coreutils + awk + od only, so it
// runs on the Alpine lab and the Debian/Ubuntu-based images alike (no sox).
public enum DozSound {
    public static let path = "/usr/local/bin/doz-sound"
    public static let stamp = "doz:doz-sound:v1"
    public static let confPath = "/etc/dozer/doz-sound.conf"
    public static let asoundPath = "/etc/asound.conf"
    public static let asoundStamp = "doz:asound:v2"

    /// The app name doz-sound names in its permission hint, made safe for a single-quoted shell value.
    static func safeAppName(_ s: String?) -> String {
        let name = (s ?? "").filter { $0.isLetter || $0.isNumber || " ._-()".contains($0) }
        return name.isEmpty ? "the app that started doz" : String(name.prefix(80))
    }

    /// Root shell (part of the tools layer's apply script): write /etc/asound.conf from the card the guest has —
    /// playback and capture straight from its two devices (one program at a time each: dmix STALLS on this card —
    /// its writes never complete, measured; v1 used it, so v2 replaces a v1 file). Says `doz-tool asound-conf …`.
    static func asoundScript(say: (String, String, String) -> String) -> String {
        let card = #"s/^card \([0-9]*\):.*device \([0-9]*\):.*/\1,\2/p"#
        return """
        if grep -qs '\(asoundStamp)' '\(asoundPath)'; then \(say("asound-conf", "ok", "default = the virtio card (its playback and capture devices)"))\
        else P=$(aplay -l 2>/dev/null | sed -n '\(card)' | head -1); R=$(arecord -l 2>/dev/null | sed -n '\(card)' | head -1); \
        if [ -z "$P" ]; then \(say("asound-conf", "failed", "no sound card in the guest — is it booted with the sound kernel?"))\
        else C=${P%,*}; [ -f '\(asoundPath)' ] && mv -f '\(asoundPath)' '\(asoundPath).doz-backup'; \
        { echo '# \(asoundStamp) — written by Dozer (EXPERIMENTAL audio). The virtio card has separate playback and capture'; \
        echo '# devices; default joins them (one program at a time on each — dmix stalls on this card).'; \
        if [ -n "$R" ]; then echo "pcm.!default { type asym playback.pcm \\"plughw:$P\\" capture.pcm \\"plughw:$R\\" }"; \
        else echo "pcm.!default { type asym playback.pcm \\"plughw:$P\\" }"; fi; \
        echo "ctl.!default { type hw card $C }"; } > '\(asoundPath)' && chmod 0644 '\(asoundPath)' && \
        \(say("asound-conf", "installed", "default = the virtio card (its playback and capture devices)"))fi; fi;
        """
    }

    /// Root shell: install doz-sound (when its stamp is not there) and write its conf (always — the Mac app it names
    /// follows the host). Says `doz-tool doz-sound …`.
    static func installScript(app: String?, say: (String, String, String) -> String) -> String {
        let b64 = Data(script.utf8).base64EncodedString()
        let conf = "MAC_APP='\(safeAppName(app))'"
        return """
        mkdir -p /etc/dozer && printf '%s\\n' "\(conf)" > '\(confPath)'; \
        if grep -qs '\(stamp)' '\(path)'; then \(say("doz-sound", "ok", "TEMPORARY: doz-sound info | test | rec FILE [SECONDS] | play FILE"))\
        else mkdir -p /usr/local/bin && printf '%s' '\(b64)' | base64 -d > '\(path).tmp' && chmod 0755 '\(path).tmp' && mv -f '\(path).tmp' '\(path)' && \
        \(say("doz-sound", "installed", "TEMPORARY: doz-sound info | test | rec FILE [SECONDS] | play FILE"))fi;
        """
    }

    /// The TEMPORARY script itself.
    public static let script = #"""
    #!/bin/sh
    # doz:doz-sound:v1 — TEMPORARY. Dozer's EXPERIMENTAL audio sandboxes: record and play through the Mac's
    # microphone and speakers (virtio-snd → ALSA). Written by Dozer's tools layer; it goes when the experiment does.
    #   doz-sound info                card, devices, the default
    #   doz-sound test                a quiet 0.8 s tone, then 3 s from the microphone (its level), played back
    #   doz-sound rec FILE [SECONDS]  record a WAV (default 5 s)
    #   doz-sound play FILE           play a WAV
    #   doz-sound tone FILE           write a quiet 0.8 s 440 Hz test tone (a WAV) to play
    # A recording that gets no audio ends within seconds (never hangs) and says why.
    set -u
    MAC_APP="the app that started doz"
    [ -r /etc/dozer/doz-sound.conf ] && . /etc/dozer/doz-sound.conf
    T=$(mktemp -d 2>/dev/null || echo /tmp/doz-sound.$$); mkdir -p "$T"; trap 'rm -rf "$T"' EXIT INT TERM
    die() { echo "doz-sound: $*" >&2; exit 1; }
    command -v aplay >/dev/null 2>&1 || die "aplay is missing — the tools layer installs alsa-utils (doz tools NAME --apply on the Mac)"
    aplay -l 2>/dev/null | grep -q '^card' || die "no sound card here — this sandbox was not created with --audio (or its kernel is not the sound kernel)"
    noaudio() {
      echo "doz-sound: no audio from the Mac's microphone — macOS permission? (System Settings › Privacy & Security › Microphone: allow $MAC_APP, then try again)." >&2
      echo "doz-sound: until that is settled, Shut Down this sandbox rather than pause, sleep or hibernate it (a capture waiting on macOS can make the VM stop)." >&2
    }
    # level FILE.wav → "dBFS non-zero total glitches"   (glitches: lone -32768 samples the device inserts; not counted)
    level() { tail -c +45 "$1" | od -An -v -td2 | awk '{for(i=1;i<=NF;i++){v=$i;n++;if(v==-32768){g++;continue};if(v!=0)z++;x=v/32768;s+=x*x;m++}} END{if(m==0){printf "none 0 %d %d\n",n,g;exit};r=sqrt(s/m);printf "%.1f %d %d %d\n",(r>0?20*log(r)/log(10):-999),z,n,g}'; }
    # tone FILE SECONDS → a 440 Hz sine at -20 dBFS (raw S16_LE mono 48 kHz), faded in and out
    tone() {
      awk -v n="$(awk -v s="$2" 'BEGIN{print int(s*48000)}')" 'BEGIN{f=2400;for(i=0;i<n;i++){e=1;if(i<f)e=i/f;if(i>n-f)e=(n-i)/f;v=int(3277*e*sin(6.283185307179586*440*i/48000));if(v<0)v+=65536;printf "\\%03o\\%03o",v%256,int(v/256)}}' > "$T/tone.esc"
      printf "$(cat "$T/tone.esc")" > "$1"
    }
    le() { awk -v v="$1" -v n="$2" 'BEGIN{for(i=0;i<n;i++){printf "\\%03o",v%256;v=int(v/256)}}'; }
    # wav RAW WAV → a WAV file (PCM S16_LE mono 48 kHz) around the raw samples
    wav() { b=$(wc -c < "$1" | tr -d ' '); printf "RIFF$(le $((b + 36)) 4)WAVEfmt $(le 16 4)$(le 1 2)$(le 1 2)$(le 48000 4)$(le 96000 4)$(le 2 2)$(le 16 2)data$(le "$b" 4)" > "$2" && cat "$1" >> "$2"; }
    # rec FILE SECONDS → 0 heard, 3 no audio
    rec() {
      rm -f "$1"
      timeout $(( $2 + 6 )) arecord -q -D default -f S16_LE -r 48000 -c 1 -t wav -d "$2" "$1" 2>"$T/arec.err"; rc=$?
      set -- "$1" "$2" $( [ -s "$1" ] && level "$1" || echo "none 0 0 0" )
      if [ "$rc" != 0 ] || [ "$3" = none ] || [ "$4" -lt $(( $5 / 100 + 1 )) ]; then
        [ -s "$T/arec.err" ] && sed 's/^/doz-sound: arecord: /' "$T/arec.err" >&2
        [ "$rc" = 124 ] && echo "doz-sound: the recording got nothing for $(( $2 + 6 )) s and was stopped" >&2
        noaudio; return 3
      fi
      echo "level: $3 dBFS ($4 of $5 samples non-zero$( [ "$6" != 0 ] && echo ", $6 glitch samples ignored"))"
      return 0
    }
    case "${1:-}" in
      info)
        echo "kernel: $(uname -r)"; aplay -l 2>/dev/null | grep '^card' | sed 's/^/playback: /'; arecord -l 2>/dev/null | grep '^card' | sed 's/^/capture:  /'
        echo "default: $(grep -E '^pcm.!default' /etc/asound.conf 2>/dev/null || echo 'ALSA built-in (no /etc/asound.conf)')"
        echo "the Mac's microphone is asked for on behalf of: $MAC_APP" ;;
      test)
        echo "playing a quiet 440 Hz tone (0.8 s)…"; tone "$T/tone.raw" 0.8; wav "$T/tone.raw" "$T/tone.wav"
        timeout 20 aplay -q -D default "$T/tone.wav" || die "playback failed"
        echo "recording 3 s from the Mac's microphone — say something…"
        rec "$T/rec.wav" 3 || exit 3
        echo "playing the recording back…"; timeout 20 aplay -q -D default "$T/rec.wav" || die "playback failed" ;;
      rec)
        [ $# -ge 2 ] || die "usage: doz-sound rec FILE [SECONDS]"
        s=${3:-5}; case "$s" in ''|*[!0-9]*) die "SECONDS is a whole number";; esac
        rec "$2" "$s" || exit 3; echo "wrote $2" ;;
      tone)
        [ $# -ge 2 ] || die "usage: doz-sound tone FILE"
        tone "$T/tone.raw" 0.8 && wav "$T/tone.raw" "$2" && echo "wrote $2 (0.8 s, 440 Hz, quiet)" ;;
      play)
        [ $# -ge 2 ] && [ -r "$2" ] || die "usage: doz-sound play FILE (a WAV)"
        timeout $(( 10 * 60 )) aplay -q -D default "$2" ;;
      *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; [ -n "${1:-}" ] && exit 2 ;;
    esac
    """#
}
