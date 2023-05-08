#!/bin/bash
[[ $DEBUG ]] && set -o nounset # set -u causes errors i'm too lazy to fix rn
set -o pipefail -o errexit -o errtrace
trap 'echo -e "${FMT_BOLD}ERROR${FMT_OFF}: at $FUNCNAME:$LINENO"' ERR

readonly PROGNAME="$( basename $0 )"
# compute version from script moddate
RES="$( stat -c %y $0 | cut -d" " -f1 )"
readonly VERSION=${RES//-/}
RES=

## TODO
# - $outfile seems to cause problems on WSL ? weird
# - we should resize frame even when -1 is used for scaling

FFMPEG="${FFMPEG:-ffmpeg}"
FFPROBE="${FFPROBE:-ffprobe}"
INFILE_IMG=
INFILE_AUDIO=
SS_OPT=
T_OPT=
OUTFILE_PREFIX=/tmp/ffpodclip-out
OUTFILE_EXT=mp4
OUTFILE=
OPT_OVERWRITE=0
CRF=18
SIZE_OPT=
FF_OPTS="-c:v libx264 -framerate 1 -tune:v stillimage -preset:v fast -pix_fmt yuv420p -c:a copy"
TWITTER_MODE=0
FF_OPTS_TWITTER="-c:v libx264 -framerate 1 -tune:v stillimage -preset:v medium -profile:v high -pix_fmt yuv420p -c:a aac -b:a 192k -ac 2 -ar 44100"


# $1 = command to test (string)
fn_need_cmd() {
    if ! command -v "$1" > /dev/null 2>&1
        then
            fn_say "need '$1' (command not found)"
            exit 255
    fi
}
# $1 = message (string)
fn_say() {
    echo -e "$PROGNAME: $1"
}

fn_help() {
    cat << EOF
$PROGNAME v$VERSION
        Takes an image and an audio track and creates a video from it.

REQUIREMENTS
        ffmpeg, mimetype, coreutils (stat, cut)

USAGE
        $PROGNAME AUDIO_FILE IMAGE_FILE [-o OUTPUT_FILE --ss START_TIME -t DURATION --crf CRF -s SIZE --ff-opts "FF_OPTS" --twitter-mode -y --dry-run]

OPTIONS AND ARGUMENTS
        AUDIO_FILE      path to audio file (if more than 2 is provided, the last one is used)
        IMAGE_FILE      path to image file (if more than 2 is provided, the last one is used)
                        NB: The image's width and height must be divisible by 2. If it is not
			the case, the image will be resized by 1 pixel.
        OUTPUT_FILE     path to output file [default: $OUTFILE_PREFIX.$OUTFILE_EXT]
	START_TIME 	start timestamp of the audio track (ffmpeg -ss option) [default: (unset)]
	DURATION 	duration time of the audio track (ffmpeg -t option) [default: whole audio track]
        CRF             quality of the output video (constant rate factor) [default: $CRF]
        SIZE            size of output video (WIDTHxHEIGHT) ; specifying -1 will use a value
			that maintains the aspect ratio of the input image
			[default: (no change)]
        FF_OPTS         ffmpeg options to pass to the final command (use quotes) 
                        [default: "$FF_OPTS"]
        --twitter-mode  add ffmpeg options for twitter compatibility; overwrite FF_OPTS
        -y              option to overwrite output file
        --dry-run       show the computed ffmpeg command with running it

EXAMPLE
        $ $PROGNAME example.png example.m4a -o out_example.mp4 -crf 25
        $ $PROGNAME me_talking.opus my_painting.png -o humble_video.mkv --crf 21 -s 1080x-1
        $ $PROGNAME pic.jpg audio.mp3 --crf 15 -ss 65 -t 15 --dry-run

TWITTER "MEDIA BEST PRACTICES"
        - Recommended Video Codec: H264 High Profile
        - Recommended Frame Rates: 30 FPS, 60 FPS
        - Recommended Video Resolution: 1280x720 (landscape), 720x1280 (portrait), 720x720 (square)
	- Recommended Minimum Video Bitrate: 5,000 kbps
        - Recommended Minimum Audio Bitrate: 128 kbps
        - Recommended Audio Codec: AAC LC
        - Recommended Aspect Ratio: 16:9 (landscape or portrait), 1:1 (square)

REFERENCES
	FFMPEG libx264 encoding guide: <https://trac.ffmpeg.org/wiki/Encode/H.264>
	Twitter media best practices: <https://developer.twitter.com/en/docs/twitter-api/v1/media/upload-media/uploading-media/media-best-practices>

AUTHOR
        Written by Sylvain Saubier

REPORTING BUGS
        Mail at: <feedback@sylsau.com>
EOF
}


fn_need_cmd "$FFMPEG"
fn_need_cmd "$FFPROBE"
fn_need_cmd "mimetype"

if test -z "$*"; then
    fn_help
    exit 10
else
    # Individually check provided args
    while test -n "$1" ; do
        case "$1" in
            "--help"|"-h")
                fn_help
                exit
                ;;
            "-o")
                OUTFILE="$2"
                shift
                ;;
	    "-y")
                OPT_OVERWRITE=1
		;;
            "-crf")
		# TODO: currently cannot disable CRF (for example with an encoder that does not support crf)
                CRF="$2"
                shift
                ;;
            "--crf")
		# TODO: currently cannot disable CRF (for example with an encoder that does not support crf)
                CRF="$2"
                shift
                ;;
            "-s")
                SIZE_OPT="$2"
                shift
                ;;
	    "-ss")
		SS_OPT="-ss $2"
		shift
		;;
	    "--ss")
		SS_OPT="-ss $2"
		shift
		;;
	    "-t")
		T_OPT="-t $2"
		shift
		;;
            "--twitter-mode")
                TWITTER_MODE=1
                ;;
            "--ff-opts")
                FF_OPTS="$2"
                shift
                ;;
            "--dry-run")
                DEBUG=1
                ;;
            *)
		# TODO: error if more than 2 input files are given
		# TODO: should be done with ffprobe
		RES=$(mimetype --output-format '%m' "$1")
		if [[ "$RES" =~ ^image/ ]]; then
			INFILE_IMG="$1"
		elif [[ "$RES" =~ ^audio/ ]]; then
			# if audio is AAC/MP4 or MP3, then container is MP4,  else it's MKV
			if [[ "$RES" != "audio/aac" && "$RES" != "audio/mp4" && "$RES" != "audio/mpeg" ]]; then
				OUTFILE_EXT=mkv
			fi
			INFILE_AUDIO="$1"
		else
			fn_say "not an image or an audio file!"
			exit 20
		fi
		;;
        esac	# --- end of case ---
        # Delete $1
        shift
    done
fi

if [[ -z "$INFILE_IMG" || -z "$INFILE_AUDIO" ]]; then
    fn_say "need one image and one audio track !"
    exit 30
fi
# if OUTFILE was not provided, compute new default outfile path
if [[ -z "$OUTFILE" ]]; then
	OUTFILE="$OUTFILE_PREFIX.$OUTFILE_EXT"
fi
if [[ "$OPT_OVERWRITE" ]]; then
	FF_OPTS="$FF_OPTS -y"
fi

# duration check
if [[ -z "$SS_OPT" ]]; then
	T_OPT="-t $($FFPROBE -v error -i "$INFILE_AUDIO" -show_entries format=duration -of csv="p=0")"
elif [[ -z "$T_OPT" ]]; then
	fn_say "need start time and duration time !"
	exit 40
fi

# if w or h of source image is not divisible by 2, fix it in the output
if [[ -z "$SIZE_OPT" ]]; then
	RES=$($FFPROBE -v error -i "$INFILE_IMG" -show_entries stream=width,height -of csv="p=0")
	if [[ $(( $(cut -d, -f1 <<<"$RES") % 2 )) -ne 0 ]]; then
		RES="$(( $(cut -d, -f1 <<<"$RES") - 1)),$(cut -d, -f2 <<<"$RES")"
	fi
	if [[ $(( $(cut -d, -f2 <<<"$RES") % 2 )) -ne 0 ]]; then
		RES="$(cut -d, -f1 <<<"$RES"),$(( $(cut -d, -f2 <<<"$RES") - 1))"
		#SIZE_OPT=${SIZE_OPT/H/$(( $(cut -d, -f2 <<<"$RES") - 1))}
	fi
	SIZE_OPT="-vf scale=${RES/,/:}"
	fn_say "image was resized by 1 pixel (width and height need to be divisible by 2)"
else
# allow for -1 to specify scale with appropriate aspect ratio accroding to source
	SIZE_OPT="-vf scale=${SIZE_OPT/x/:}"
fi

# override FF_OPTS with twitter-compatible options
if [[ $TWITTER_MODE -eq 1 ]]; then
	FF_OPTS="$FF_OPTS_TWITTER"
fi

CMD=$FFMPEG -loop 1 -i "$INFILE_IMG" $SS_OPT -i "$INFILE_AUDIO" -map 0:v -map 1:a $FF_OPTS -crf:v $CRF $SIZE_OPT $T_OPT $OUTFILE
fn_say "\nFFMPEG COMMAND\n\t${CMD}\n"
if [[ -z "$DEBUG" ]]; then
	$CMD
fi

fn_say "output to $OUTFILE"
fn_say "all done!"
