-- =============================================================================
-- 0091_carrier_required_agreement_column_grants.sql
-- Phase 2L.7D: expose required-agreement initialization metadata to staff.
-- =============================================================================

grant select (
  agreement_requirements_initialized_at,
  agreement_requirements_initialized_by
)
on public.carrier_onboarding_applications
to authenticated;
