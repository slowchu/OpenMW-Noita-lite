local runtime_stats = {}

local counters = {}

local function asNumber(value)
    return tonumber(value) or 0
end

function runtime_stats.inc(name, amount)
    if type(name) ~= "string" or name == "" then
        return 0
    end
    local delta = amount == nil and 1 or asNumber(amount)
    counters[name] = asNumber(counters[name]) + delta
    return counters[name]
end

function runtime_stats.max(name, value)
    if type(name) ~= "string" or name == "" then
        return 0
    end
    local next_value = asNumber(value)
    local current = asNumber(counters[name])
    if next_value > current then
        counters[name] = next_value
    elseif counters[name] == nil then
        counters[name] = current
    end
    return counters[name]
end

function runtime_stats.get(name)
    return asNumber(counters[name])
end

function runtime_stats.snapshot()
    local out = {}
    for name, value in pairs(counters) do
        out[name] = value
    end
    return out
end

function runtime_stats.reset()
    counters = {}
end

local function g(name)
    return runtime_stats.get(name)
end

function runtime_stats.summaryLines()
    return {
        string.format(
            "dispatch attempts=%d dry_run=%d qualified=%d rejected=%d ok=%d failed=%d fallback=%d suppressed=%d blocked=%d duplicate_suppressed=%d",
            g("live_2_2c_attempts"),
            g("live_2_2c_dry_run_attempts"),
            g("live_2_2c_qualified"),
            g("live_2_2c_rejected"),
            g("live_2_2c_dispatch_ok"),
            g("live_2_2c_dispatch_failed"),
            g("legacy_fallback_used"),
            g("compiled_dispatch_suppressed"),
            g("fallback_after_enqueue_blocked"),
            g("duplicate_cast_or_dispatch_suppressed")
        ),
        string.format(
            "plans compiled=%d reused=%d helpers attached=%d created=%d reused=%d attach_failed=%d",
            g("plans_compiled"),
            g("plans_reused"),
            g("helper_records_attached"),
            g("helper_records_created"),
            g("helper_records_reused"),
            g("helper_records_attach_failed")
        ),
        string.format(
            "jobs enqueued=%d live_enqueued=%d processed=%d live_processed=%d failed=%d live_failed=%d expired=%d skipped_not_ready=%d max_queue=%d drained=%d",
            g("jobs_enqueued"),
            g("live_helper_jobs_enqueued"),
            g("jobs_processed"),
            g("live_helper_jobs_processed"),
            g("jobs_failed"),
            g("live_helper_jobs_failed"),
            g("jobs_expired"),
            g("jobs_skipped_not_ready"),
            g("max_queue_depth"),
            g("queue_drained_observed")
        ),
        string.format(
            "sfp launch attempts=%d ok=%d failed=%d missing_interface=%d projectile_id=%d projectile_missing=%d",
            g("sfp_launch_attempts"),
            g("sfp_launch_ok"),
            g("sfp_launch_failed"),
            g("sfp_launch_missing_interface"),
            g("sfp_projectile_id_returned"),
            g("sfp_projectile_id_missing")
        ),
        string.format(
            "sfp adapter launch calls=%d ok=%d failed=%d detonate calls=%d ok=%d failed=%d missing_detonate=%d cancel calls=%d ok=%d failed=%d missing_cancel=%d area_vfx=%d area_scale=%d exclude_target=%d",
            g("sfp_adapter_launch_calls"),
            g("sfp_adapter_launch_ok"),
            g("sfp_adapter_launch_failed"),
            g("sfp_adapter_detonate_calls"),
            g("sfp_adapter_detonate_ok"),
            g("sfp_adapter_detonate_failed"),
            g("sfp_adapter_missing_detonate"),
            g("sfp_adapter_cancel_calls"),
            g("sfp_adapter_cancel_ok"),
            g("sfp_adapter_cancel_failed"),
            g("sfp_adapter_missing_cancel"),
            g("sfp_adapter_area_vfx_forwarded"),
            g("sfp_adapter_area_vfx_scale_forwarded"),
            g("sfp_adapter_exclude_target_forwarded")
        ),
        string.format(
            "hits seen=%d userData=%d spellIdFallback=%d unresolved=%d mismatch=%d live=%d dev=%d legacy=%d",
            g("hits_seen"),
            g("hits_userdata_routed"),
            g("hits_spellid_fallback_routed"),
            g("hits_unresolved"),
            g("hits_userdata_mismatch"),
            g("hits_live_helper_seen"),
            g("hits_dev_helper_seen"),
            g("hits_legacy_seen")
        ),
        string.format(
            "cast_ids created=%d missing=%d reused_unexpected=%d compiled_ok=%d",
            g("cast_ids_created"),
            g("cast_ids_missing"),
            g("cast_ids_reused_unexpectedly"),
            g("compiled_dispatch_ok")
        ),
        string.format(
            "multicast attempts=%d qualified=%d rejected=%d planned=%d jobs=%d cap_reject=%d payload_reject=%d unsupported_reject=%d",
            g("live_multicast_attempts"),
            g("live_multicast_qualified"),
            g("live_multicast_rejected"),
            g("live_multicast_emissions_planned"),
            g("live_multicast_jobs_enqueued"),
            g("live_multicast_cap_rejections"),
            g("live_multicast_payload_rejections"),
            g("live_multicast_unsupported_opcode_rejections")
        ),
        string.format(
            "spread attempts=%d qualified=%d rejected=%d planned=%d burst attempts=%d qualified=%d rejected=%d planned=%d pattern_jobs=%d pattern_failed=%d payload_reject=%d unsupported_reject=%d",
            g("live_spread_attempts"),
            g("live_spread_qualified"),
            g("live_spread_rejected"),
            g("live_spread_emissions_planned"),
            g("live_burst_attempts"),
            g("live_burst_qualified"),
            g("live_burst_rejected"),
            g("live_burst_emissions_planned"),
            g("live_pattern_direction_jobs"),
            g("live_pattern_direction_failed"),
            g("live_pattern_payload_rejections"),
            g("live_pattern_unsupported_opcode_rejections")
        ),
        string.format(
            "trigger attempts=%d qualified=%d rejected=%d disabled=%d source_jobs=%d source_hits=%d payload_jobs=%d payload_processed=%d payload_ok=%d payload_failed=%d duplicate_suppressed=%d depth_reject=%d payload_missing=%d route_failed=%d post_hit_smoke=%d",
            g("live_trigger_attempts"),
            g("live_trigger_qualified"),
            g("live_trigger_rejected"),
            g("live_trigger_disabled_rejections"),
            g("live_trigger_source_jobs_enqueued"),
            g("live_trigger_source_hits"),
            g("live_trigger_payload_jobs_enqueued"),
            g("live_trigger_payload_jobs_processed"),
            g("live_trigger_payload_launch_ok"),
            g("live_trigger_payload_launch_failed"),
            g("live_trigger_duplicate_hits_suppressed"),
            g("live_trigger_depth_rejections"),
            g("live_trigger_payload_missing"),
            g("live_trigger_payload_route_failed"),
            g("live_trigger_post_hit_smoke_observed")
        ),
        string.format(
            "timer attempts=%d qualified=%d rejected=%d disabled=%d source_jobs=%d wait_jobs=%d wait_processed=%d wait_not_ready=%d wait_expired=%d payload_jobs=%d payload_processed=%d payload_ok=%d payload_failed=%d duplicate_suppressed=%d async_scheduled=%d async_callback=%d async_missing=%d async_enqueued=%d async_payload_ok=%d async_pending=%d async_cleared=%d async_dup=%d depth_reject=%d payload_missing=%d route_failed=%d delay_invalid=%d delay_capped=%d real_delay_attempts=%d real_matured=%d real_payload_ok=%d real_delay_smoke=%d real_smoke_scheduled=%d real_smoke_pending=%d real_smoke_callback_ok=%d immediate_blocked=%d source_detonation_blocked=%d",
            g("live_timer_attempts"),
            g("live_timer_qualified"),
            g("live_timer_rejected"),
            g("live_timer_disabled_rejections"),
            g("live_timer_source_jobs_enqueued"),
            g("live_timer_wait_jobs_enqueued"),
            g("live_timer_wait_jobs_processed"),
            g("live_timer_wait_jobs_not_ready"),
            g("live_timer_wait_jobs_expired"),
            g("live_timer_payload_jobs_enqueued"),
            g("live_timer_payload_jobs_processed"),
            g("live_timer_payload_launch_ok"),
            g("live_timer_payload_launch_failed"),
            g("live_timer_duplicate_schedules_suppressed"),
            g("live_timer_async_scheduled"),
            g("live_timer_async_callback_seen"),
            g("live_timer_async_callback_missing"),
            g("live_timer_async_payload_enqueued"),
            g("live_timer_async_payload_ok"),
            g("live_timer_async_pending"),
            g("live_timer_async_pending_cleared"),
            g("live_timer_async_duplicate_suppressed"),
            g("live_timer_depth_rejections"),
            g("live_timer_payload_missing"),
            g("live_timer_payload_route_failed"),
            g("live_timer_delay_invalid"),
            g("live_timer_delay_capped"),
            g("live_timer_real_delay_attempts"),
            g("live_timer_real_delay_matured"),
            g("live_timer_real_delay_payload_ok"),
            g("live_timer_real_delay_smoke_observed"),
            g("live_timer_real_delay_smoke_scheduled"),
            g("live_timer_real_delay_smoke_pending"),
            g("live_timer_real_delay_smoke_callback_ok"),
            g("live_timer_immediate_payload_blocked"),
            g("timer_source_detonation_blocked")
        ),
        string.format(
            "impact_vfx metadata_present=%d metadata_missing=%d default_area_fallback=%d area_override=%d invalid_area_override_suppressed=%d hit_model_attempted=%d spawn_failed=%d",
            g("impact_vfx_metadata_present"),
            g("impact_vfx_metadata_missing"),
            g("impact_vfx_default_area_fallback_used"),
            g("impact_vfx_area_override_used"),
            g("impact_vfx_invalid_area_override_suppressed"),
            g("impact_vfx_hit_model_spawn_attempted"),
            g("impact_vfx_spawn_failed")
        ),
        string.format(
            "speed_plus attempts=%d qualified=%d rejected=%d disabled=%d jobs_mutated=%d invalid=%d capped=%d field_missing=%d payload_reject=%d unsupported_reject=%d smoke=%d",
            g("live_speed_plus_attempts"),
            g("live_speed_plus_qualified"),
            g("live_speed_plus_rejected"),
            g("live_speed_plus_disabled_rejections"),
            g("live_speed_plus_jobs_mutated"),
            g("live_speed_plus_value_invalid"),
            g("live_speed_plus_value_capped"),
            g("live_speed_plus_field_missing"),
            g("live_speed_plus_payload_rejections"),
            g("live_speed_plus_unsupported_combo_rejections"),
            g("live_speed_plus_smoke_observed")
        ),
        string.format(
            "size_plus attempts=%d qualified=%d rejected=%d disabled=%d jobs_mutated=%d specs_mutated=%d invalid=%d capped=%d field_missing=%d payload_reject=%d unsupported_reject=%d smoke=%d",
            g("live_size_plus_attempts"),
            g("live_size_plus_qualified"),
            g("live_size_plus_rejected"),
            g("live_size_plus_disabled_rejections"),
            g("live_size_plus_jobs_mutated"),
            g("live_size_plus_specs_mutated"),
            g("live_size_plus_value_invalid"),
            g("live_size_plus_value_capped"),
            g("live_size_plus_field_missing"),
            g("live_size_plus_payload_rejections"),
            g("live_size_plus_unsupported_combo_rejections"),
            g("live_size_plus_smoke_observed")
        ),
    }
end

return runtime_stats
