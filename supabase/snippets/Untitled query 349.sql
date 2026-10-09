select 'patients' as tbl, count(*) from patients
union all select 'caregivers', count(*) from caregivers
union all select 'prescriptions', count(*) from prescriptions
union all select 'prescription_medicines', count(*) from prescription_medicines
union all select 'compartments', count(*) from compartments
union all select 'schedules', count(*) from schedules
union all select 'adherence_log', count(*) from adherence_log;