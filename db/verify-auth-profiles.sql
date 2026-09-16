-- =====================================================================
--  Ellenőrzés: minden auth.users sorhoz van-e mk_profiles bejegyzés
--  helyes céggel és szerepkörrel.
--
--  Miért fontos: egy auth.users fiók, ami be tud jelentkezni, de nincs
--  mk_profiles sora, `mk_current_company()` = NULL-t kap – az iroda
--  üres/hibás képernyőt látna, RLS miatt semmit sem érne el.
--
--  Bármikor futtatható (nem csak a "kiürítés + friss telepítés" után),
--  staging vagy éles SQL Editorban.
-- =====================================================================

select
  case when not exists (
         select 1 from auth.users u
         left join public.mk_profiles p on p.user_id = u.id
        where p.user_id is null)
       then '✅ OK – minden auth.users fiókhoz van mk_profiles bejegyzés'
       else '❌ HIÁNY – van bejelentkezni tudó fiók cégprofil nélkül, lásd lent'
  end as osszegzes;

select
  u.id                                              as user_id,
  u.email,
  p.role,
  c.name                                             as company_name,
  case when p.user_id is null
       then '⚠️ HIÁNYZIK A PROFIL – be tud lépni, de nincs cége (üres/hibás képernyőt kapna)'
       else 'OK'
  end                                                as status
from auth.users u
left join public.mk_profiles p on p.user_id = u.id
left join public.mk_companies c on c.id = p.company_id
order by (p.user_id is null) desc, u.email;
