#!/bin/sh
# Diagnostic runtime CPU0. Tous les reglages modifies sont restaures a la sortie.
set -eu

TRACE=/sys/kernel/tracing
CYCLICTEST=${CYCLICTEST:-/tmp/cyclictest}
OUT=${OUT:-/tmp/campagne-cpu0}
TEST_DURATION=${TEST_DURATION:-90s}
TRACE_SECONDS=${TRACE_SECONDS:-60}
HWLAT_SECONDS=${HWLAT_SECONDS:-30}

mkdir -p "$OUT/state"
if test -x "$CYCLICTEST"; then
	: cyclictest found
else
	printf 'WARNING: cyclictest not found at %s, skipping cyclictest tests\n' "$CYCLICTEST" >&2
	CYCLICTEST=
fi
test -d "$TRACE"

read_file()
{
	test -r "$1" && cat "$1" || true
}

save_state()
{
	read_file "$TRACE/tracing_on" > "$OUT/state/tracing_on"
	read_file "$TRACE/current_tracer" > "$OUT/state/current_tracer"
	read_file "$TRACE/tracing_cpumask" > "$OUT/state/tracing_cpumask"
	read_file "$TRACE/buffer_size_kb" | cut -d' ' -f1 > "$OUT/state/buffer_size_kb"
	read_file "$TRACE/tracing_thresh" > "$OUT/state/tracing_thresh"
	read_file "$TRACE/set_event" > "$OUT/state/set_event"
	read_file "$TRACE/set_ftrace_filter" > "$OUT/state/set_ftrace_filter"
	for name in cpus period_us runtime_us stop_tracing_total_us \
		stop_tracing_us timerlat_period_us print_stack; do
		read_file "$TRACE/osnoise/$name" > "$OUT/state/osnoise-$name"
	done
	for name in width window; do
		read_file "$TRACE/hwlat_detector/$name" > "$OUT/state/hwlat-$name"
	done
	read_file "$TRACE/hwlat_detector/mode" | tr ' ' '\n' | \
		sed -n 's/^\[\(.*\)\]$/\1/p' > "$OUT/state/hwlat-mode"
	for f in /sys/devices/system/cpu/cpu0/cpuidle/state*/disable; do
		state=${f%/disable}
		state=${state##*/}
		read_file "$f" > "$OUT/state/idle-$state"
	done
	for irq in 255 256; do
		read_file "/proc/irq/$irq/smp_affinity_list" > "$OUT/state/irq-$irq"
	done
	systemctl is-active irqbalance.service > "$OUT/state/irqbalance" 2>&1 || true
}

restore_state()
{
	printf 0 > "$TRACE/tracing_on" || true
	printf 0 > "$TRACE/events/enable" || true
	printf nop > "$TRACE/current_tracer" || true
	for name in cpus period_us runtime_us stop_tracing_total_us \
		stop_tracing_us timerlat_period_us print_stack; do
		value=$(read_file "$OUT/state/osnoise-$name")
		test -n "$value" && printf '%s' "$value" > "$TRACE/osnoise/$name" || true
	done
	for name in mode width window; do
		value=$(read_file "$OUT/state/hwlat-$name")
		test -n "$value" && printf '%s' "$value" > "$TRACE/hwlat_detector/$name" || true
	done
	value=$(read_file "$OUT/state/tracing_thresh")
	test -n "$value" && printf '%s' "$value" > "$TRACE/tracing_thresh" || true
	value=$(read_file "$OUT/state/tracing_cpumask")
	test -n "$value" && printf '%s' "$value" > "$TRACE/tracing_cpumask" || true
	value=$(read_file "$OUT/state/buffer_size_kb")
	test -n "$value" && printf '%s' "$value" > "$TRACE/buffer_size_kb" || true
	: > "$TRACE/set_ftrace_filter" || true
	# Les filtres precedents ne sont recharges que si le tracer les accepte.
	if test -s "$OUT/state/set_ftrace_filter"; then
		while IFS= read -r function; do
			test -n "$function" || continue
			printf '%s\n' "$function" >> "$TRACE/set_ftrace_filter" 2>/dev/null || true
		done < "$OUT/state/set_ftrace_filter"
	fi
	while IFS= read -r event; do
		test -n "$event" && printf '%s\n' "$event" >> "$TRACE/set_event" || true
	done < "$OUT/state/set_event"
	value=$(read_file "$OUT/state/current_tracer")
	test -n "$value" && printf '%s' "$value" > "$TRACE/current_tracer" || true
	for f in /sys/devices/system/cpu/cpu0/cpuidle/state*/disable; do
		state=${f%/disable}
		state=${state##*/}
		value=$(read_file "$OUT/state/idle-$state")
		test -n "$value" && printf '%s' "$value" > "$f" || true
	done
	for irq in 255 256; do
		value=$(read_file "$OUT/state/irq-$irq")
		test -n "$value" && printf '%s' "$value" > "/proc/irq/$irq/smp_affinity_list" || true
	done
	if grep -qx active "$OUT/state/irqbalance"; then
		systemctl start irqbalance.service || true
	else
		systemctl stop irqbalance.service || true
	fi
	value=$(read_file "$OUT/state/tracing_on")
	test -n "$value" && printf '%s' "$value" > "$TRACE/tracing_on" || true
}

inventory()
{
	label=$1
	{
		date -Iseconds
		uname -a
		printf 'cmdline='; cat /proc/cmdline
		printf 'current_tracer='; cat "$TRACE/current_tracer"
		printf 'tracing_on='; cat "$TRACE/tracing_on"
		printf 'clocksource='; cat /sys/devices/system/clocksource/clocksource0/current_clocksource
		printf 'clockevent='; cat /sys/devices/system/clockevents/clockevent0/current_device
		printf 'timer_migration='; cat /proc/sys/kernel/timer_migration
		printf 'sched_rt_runtime_us='; cat /proc/sys/kernel/sched_rt_runtime_us
		printf 'irqbalance='; systemctl is-active irqbalance.service || true
		for f in /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor \
			/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq \
			/sys/devices/system/cpu/cpu0/cpuidle/state*/name \
			/sys/devices/system/cpu/cpu0/cpuidle/state*/latency \
			/sys/devices/system/cpu/cpu0/cpuidle/state*/disable; do
			test -r "$f" && printf '%s=%s\n' "$f" "$(cat "$f")"
		done
		for irq in 13 255 256; do
			printf 'irq%s_affinity=' "$irq"; read_file "/proc/irq/$irq/smp_affinity_list"
			printf 'irq%s_effective=' "$irq"; read_file "/proc/irq/$irq/effective_affinity_list"
		done
		cat /proc/interrupts
	} > "$OUT/inventory-$label.txt"
}

trace_reset()
{
	printf 0 > "$TRACE/tracing_on"
	printf 0 > "$TRACE/events/enable"
	printf nop > "$TRACE/current_tracer"
	: > "$TRACE/set_ftrace_filter"
	printf 1 > "$TRACE/tracing_cpumask"
	printf 32768 > "$TRACE/buffer_size_kb"
	: > "$TRACE/trace"
}

enable_event()
{
	event=$1
	filter=${2:-}
	event_dir=$TRACE/events/$event

	if test ! -e "$event_dir/enable"; then
		printf 'indisponible %s\n' "$event" >> "$OUT/timerlat-events.txt"
		return
	fi
	if test -n "$filter"; then
		printf '%s' "$filter" > "$event_dir/filter"
	fi
	printf 1 > "$event_dir/enable"
	printf 'active %s' "$event" >> "$OUT/timerlat-events.txt"
	test -z "$filter" || printf ' filter=%s' "$filter" >> "$OUT/timerlat-events.txt"
	printf '\n' >> "$OUT/timerlat-events.txt"
}

run_cyclic()
{
	label=$1
	if test -z "$CYCLICTEST"; then
		printf 'skipped (no cyclictest) %s\n' "$label" >&2
		return 0
	fi
	shift
	"$CYCLICTEST" --default-system -a 0 -t 1 -m -p99 -i200 \
		-D"$TEST_DURATION" -q "$@" > "$OUT/cyclictest-$label.txt" 2>&1 || true
}

run_latency_tracer()
{
	tracer=$1
	trace_reset
	printf '%s' "$tracer" > "$TRACE/current_tracer"
	printf 1 > "$TRACE/tracing_on"
	run_cyclic "$tracer"
	printf 0 > "$TRACE/tracing_on"
	cat "$TRACE/trace" > "$OUT/trace-$tracer.txt"
}

save_state
trap restore_state EXIT INT TERM
inventory before

# timerlat separe la latence d'arrivee IRQ, le handler et le thread.
trace_reset
printf 0 > "$TRACE/osnoise/stop_tracing_total_us"
printf 5000 > "$TRACE/osnoise/stop_tracing_us"
printf 1000 > "$TRACE/osnoise/timerlat_period_us"
printf 0 > "$TRACE/osnoise/cpus"
printf timerlat > "$TRACE/current_tracer"
: > "$OUT/timerlat-events.txt"
enable_event arch_timer/timer_irq
enable_event gic_v3/gic_v3_irq_ack 'intid == 26'
enable_event power/cpu_idle
printf 1 > "$TRACE/tracing_on"
i=0
while test "$i" -lt "$TRACE_SECONDS" && test "$(cat "$TRACE/tracing_on")" = 1; do
	sleep 1
	i=$((i + 1))
done
sleep 2
printf 0 > "$TRACE/tracing_on"
cat "$TRACE/trace" > "$OUT/trace-timerlat.txt"
printf '%s\n' "$i" > "$OUT/timerlat-seconds.txt"

# for tracer in irqsoff preemptoff preemptirqsoff; do
# 	run_latency_tracer "$tracer"
# done
#
# # osnoise mesure les interferences visibles par le noyau sur CPU0.
# trace_reset
# printf 0 > "$TRACE/osnoise/cpus"
# printf 1000000 > "$TRACE/osnoise/period_us"
# printf 900000 > "$TRACE/osnoise/runtime_us"
# printf 0 > "$TRACE/osnoise/stop_tracing_us"
# printf 0 > "$TRACE/osnoise/stop_tracing_total_us"
# printf osnoise > "$TRACE/current_tracer"
# printf 1 > "$TRACE/tracing_on"
# sleep "$TRACE_SECONDS"
# printf 0 > "$TRACE/tracing_on"
# cat "$TRACE/trace" > "$OUT/trace-osnoise.txt"

# Comparaison idle : tous desactives, puis chaque etat active seul.
for f in /sys/devices/system/cpu/cpu0/cpuidle/state*/disable; do printf 1 > "$f"; done
run_cyclic idle-all-disabled
for selected in 0 1 2; do
	for f in /sys/devices/system/cpu/cpu0/cpuidle/state*/disable; do printf 1 > "$f"; done
	printf 0 > "/sys/devices/system/cpu/cpu0/cpuidle/state$selected/disable"
	run_cyclic "idle-state${selected}-only"
done
# timerlat avec idle desactive pour confirmer
trace_reset
printf 0 > "$TRACE/osnoise/stop_tracing_total_us"
printf 5000 > "$TRACE/osnoise/stop_tracing_us"
printf 1000 > "$TRACE/osnoise/timerlat_period_us"
printf 0 > "$TRACE/osnoise/cpus"
printf timerlat > "$TRACE/current_tracer"
enable_event arch_timer/timer_irq
enable_event power/cpu_idle
printf 1 > "$TRACE/tracing_on"
sleep "$TRACE_SECONDS"
printf 0 > "$TRACE/tracing_on"
cat "$TRACE/trace" > "$OUT/trace-timerlat-noidle.txt"

for f in /sys/devices/system/cpu/cpu0/cpuidle/state*/disable; do
	state=${f%/disable}
	state=${state##*/}
	value=$(read_file "$OUT/state/idle-$state")
	printf '%s' "$value" > "$f"
done

# # A/B IRQ limite aux deux IRQ PCIe identifiees, pour ne pas risquer la liaison SSH.
# run_cyclic irq-current
# systemctl stop irqbalance.service
# printf 1-3 > /proc/irq/255/smp_affinity_list
# printf 1-3 > /proc/irq/256/smp_affinity_list
# inventory irq-moved
# run_cyclic irq-255-256-on-1-3
# for irq in 255 256; do
# 	value=$(read_file "$OUT/state/irq-$irq")
# 	printf '%s' "$value" > "/proc/irq/$irq/smp_affinity_list"
# done
# grep -qx active "$OUT/state/irqbalance" && systemctl start irqbalance.service || true
#
# # Trace de fonctions limitee aux chemins timer et idle, avec arret au pic.
# trace_reset
# for function in arch_timer_handler_phys arch_timer_handler_virt do_idle; do
# 	printf '%s\n' "$function" >> "$TRACE/set_ftrace_filter"
# done
# printf function > "$TRACE/current_tracer"
# printf 1 > "$TRACE/events/irq/irq_handler_entry/enable"
# printf 1 > "$TRACE/events/irq/irq_handler_exit/enable"
# printf 1 > "$TRACE/events/sched/sched_waking/enable"
# printf 1 > "$TRACE/events/sched/sched_switch/enable"
# printf 1 > "$TRACE/events/power/cpu_idle/enable"
# printf 1 > "$TRACE/tracing_on"
# run_cyclic function -b 100 --tracemark
# printf 0 > "$TRACE/tracing_on"
# cat "$TRACE/trace" > "$OUT/trace-function.txt"
#
# # hwlat en dernier : fenetre courte et faible occupation CPU.
# trace_reset
# printf per-cpu > "$TRACE/hwlat_detector/mode"
# printf 50 > "$TRACE/hwlat_detector/width"
# printf 1000000 > "$TRACE/hwlat_detector/window"
# printf 100 > "$TRACE/tracing_thresh"
# printf hwlat > "$TRACE/current_tracer"
# printf 1 > "$TRACE/tracing_on"
# sleep "$HWLAT_SECONDS"
# printf 0 > "$TRACE/tracing_on"
# cat "$TRACE/trace" > "$OUT/trace-hwlat.txt"

restore_state
trap - EXIT INT TERM
inventory after
sha256sum "$OUT"/*.txt > "$OUT/SHA256SUMS"
printf 'Resultats: %s\n' "$OUT"
