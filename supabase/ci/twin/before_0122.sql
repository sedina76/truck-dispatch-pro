-- Test-only twin shim: 0121 creates the Essential/Pro plans with random ids;
-- 0122 asserts the ids production got. Give the twin the same ids.
update public.subscription_plans set id = 'f54f87ae-556d-4ae4-8db6-0fbbbac4b798' where tier = 'essential';
update public.subscription_plans set id = '2a9138f2-0514-4e32-a178-2171776e69a3' where tier = 'pro';
