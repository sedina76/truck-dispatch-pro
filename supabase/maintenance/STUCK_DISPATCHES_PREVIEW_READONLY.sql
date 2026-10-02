-- STUCK_DISPATCHES_PREVIEW_READONLY.sql -- READ ONLY, changes nothing.
-- Loads marked delivered (or later) on the LOAD page whose dispatch never
-- moved to delivered (the gap fixed by 0166 for new deliveries). Their
-- dispatch fee does not reach Dispatch Fee Invoices until repaired with
-- FIX_STUCK_DISPATCHES.sql. "will_use_date" is the delivery date the fix
-- would record: the delivery stop's departure/arrival, else the day the load
-- was last saved.
select l.load_number, l.status as load_status, d.status as dispatch_status,
       d.dispatched_at::date as dispatched,
       coalesce(s.departed_at, s.arrived_at, l.updated_at)::date as will_use_date,
       case when s.departed_at is not null then 'delivery stop departed'
            when s.arrived_at is not null then 'delivery stop arrived'
            else 'load last saved' end as date_source
from public.loads l
join public.dispatches d on d.load_id = l.id and d.status not in ('delivered', 'completed', 'cancelled')
left join lateral (select ls.departed_at, ls.arrived_at from public.load_stops ls
                   where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1) s on true
where l.status::text in ('delivered', 'pod_received', 'invoiced', 'closed')
order by l.load_number;
