-- FIX_STUCK_DISPATCHES.sql -- ONE-TIME repair (run after 0166, after
-- reviewing STUCK_DISPATCHES_PREVIEW_READONLY.sql). Marks the dispatch of
-- each load that is already delivered (or later) as delivered, dated the
-- delivery stop's departure/arrival, else the day the load was last saved.
-- Changes only those dispatches' status and delivered date; nothing billed,
-- settled or invoiced is touched. One transaction.
begin;
do $$
declare v_n int; v_left int;
begin
  if to_regprocedure('public.sync_dispatch_from_delivered_load()') is null then
    raise exception 'FIX: run 0166 first. STOP -- nothing changed.';
  end if;
  update public.dispatches d
     set status = 'delivered',
         delivered_at = coalesce(d.delivered_at, (
           select coalesce(s.departed_at, s.arrived_at, l.updated_at)
           from public.loads l
           left join lateral (select ls.departed_at, ls.arrived_at from public.load_stops ls
                              where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1) s on true
           where l.id = d.load_id))
    from public.loads l
   where l.id = d.load_id and l.status::text in ('delivered', 'pod_received', 'invoiced', 'closed')
     and d.status not in ('delivered', 'completed', 'cancelled');
  get diagnostics v_n = row_count;
  select count(*) into v_left from public.dispatches d join public.loads l on l.id = d.load_id
   where l.status::text in ('delivered', 'pod_received', 'invoiced', 'closed') and d.status not in ('delivered', 'completed', 'cancelled');
  if v_left <> 0 then raise exception 'FIX: % dispatches still not delivered. STOP -- nothing changed.', v_left; end if;
  raise notice 'FIX: % dispatches marked delivered.', v_n;
end $$;
commit;
