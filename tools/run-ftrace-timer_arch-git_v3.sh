#!/bin/sh
set -eu

TRACE=/sys/kernel/tracing
OUT=${OUT:-/tmp/timer-gic-function-trigger-$(date +%Y%m%d-%H%M%S)}
MAX_SECONDS=${MAX_SECONDS:-1800}
TVAL_THRESHOLD=${TVAL_THRESHOLD:--1920}
CPU=${1:-${CPU:-0}}

test "$#" -le 1 || {
	printf 'Usage: %s [CPU]\n' "$0" >&2
	exit 2
}
case $CPU in
	''|*[!0-9]*)
		printf 'Invalid CPU: %s\n' "$CPU" >&2
		exit 2
		;;
esac
test -d "/sys/devices/system/cpu/cpu$CPU" || {
	printf 'CPU%s does not exist\n' "$CPU" >&2
	exit 2
}
if test -r "/sys/devices/system/cpu/cpu$CPU/online"; then
	read online < "/sys/devices/system/cpu/cpu$CPU/online"
	test "$online" = 1 || {
		printf 'CPU%s is offline\n' "$CPU" >&2
		exit 2
	}
fi

CPU_MASK=$(printf '%x' "$((1 << (CPU % 32)))")
mask_word=$((CPU / 32))
while test "$mask_word" -gt 0; do
	CPU_MASK="$CPU_MASK,00000000"
	mask_word=$((mask_word - 1))
done

mkdir -p "$OUT"
test -d "$TRACE"

cleanup()
{
	set +e
	printf 0 > "$TRACE/tracing_on"
	printf 0 > "$TRACE/events/enable"
	printf '!traceoff if cpu == %s && tval < %s' "$CPU" "$TVAL_THRESHOLD" \
		> "$TRACE/events/arch_timer/timer_irq/trigger"
	printf '0' > "$TRACE/events/arch_timer/timer_irq/filter"
	printf nop > "$TRACE/current_tracer"
	: > "$TRACE/set_ftrace_filter"
}

trap cleanup EXIT INT TERM

printf 0 > "$TRACE/tracing_on"
printf 0 > "$TRACE/events/enable"
printf nop > "$TRACE/current_tracer"
: > "$TRACE/set_ftrace_filter"
printf gic_handle_irq > "$TRACE/set_ftrace_filter"
printf '%s' "$CPU_MASK" > "$TRACE/tracing_cpumask"
: > "$TRACE/trace"

for event in gic_v3/gic_v3_irq_ack \
	gic_v3/gic_v3_irq_dispatch \
	gic_v3/gic_v3_irq_handler_exit; do
	printf 'intid == 26' > "$TRACE/events/$event/filter"
	printf 1 > "$TRACE/events/$event/enable"
done

printf 1 > "$TRACE/events/arch_timer/timer_arm/enable"
printf 1 > "$TRACE/events/arch_timer/timer_irq/enable"
printf 'cpu == %s' "$CPU" > "$TRACE/events/arch_timer/timer_irq/filter"
printf 'traceoff if cpu == %s && tval < %s' "$CPU" "$TVAL_THRESHOLD" \
	> "$TRACE/events/arch_timer/timer_irq/trigger"
printf function > "$TRACE/current_tracer"

{
	date -Iseconds
	uname -a
	printf 'cpu=%s\n' "$CPU"
	printf 'threshold_tval=%s\n' "$TVAL_THRESHOLD"
	printf 'threshold_us=100 (assuming 19.2 MHz)\n'
	printf 'max_seconds=%s\n' "$MAX_SECONDS"
	printf 'current_tracer='; read value < "$TRACE/current_tracer"; printf '%s\n' "$value"
	printf 'tracing_cpumask='; read value < "$TRACE/tracing_cpumask"; printf '%s\n' "$value"
	printf 'buffer_size_kb='; read value < "$TRACE/buffer_size_kb"; printf '%s\n' "$value"
	printf 'function_filter='; read value < "$TRACE/set_ftrace_filter"; printf '%s\n' "$value"
	printf 'trigger='; read value < "$TRACE/events/arch_timer/timer_irq/trigger"; printf '%s\n' "$value"
	printf 'timer_irq_filter='; read value < "$TRACE/events/arch_timer/timer_irq/filter"; printf '%s\n' "$value"
} > "$OUT/inventory.txt"

date -Iseconds > "$OUT/start.txt"
cp /proc/interrupts "$OUT/interrupts-before.txt"
dmesg > "$OUT/dmesg-before.txt"

printf 1 > "$TRACE/tracing_on"
elapsed=0
while test "$elapsed" -lt "$MAX_SECONDS"; do
	read tracing_on < "$TRACE/tracing_on"
	test "$tracing_on" = 1 || break
	sleep 1
	elapsed=$((elapsed + 1))
done
printf 0 > "$TRACE/tracing_on"

date -Iseconds > "$OUT/end.txt"
printf '%s\n' "$elapsed" > "$OUT/elapsed-seconds.txt"
if test "$elapsed" -lt "$MAX_SECONDS"; then
	printf 'threshold-triggered\n' > "$OUT/result.txt"
else
	printf 'timeout\n' > "$OUT/result.txt"
fi
cp "$TRACE/trace" "$OUT/trace.txt"
cp /proc/interrupts "$OUT/interrupts-after.txt"
dmesg > "$OUT/dmesg-after.txt"

printf '%s\n' "$OUT"
