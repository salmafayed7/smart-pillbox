SET local check_function_bodies = off;

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON SEQUENCES FROM "anon";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON SEQUENCES FROM "authenticated";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON SEQUENCES FROM "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON FUNCTIONS FROM "anon";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON FUNCTIONS FROM "authenticated";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON FUNCTIONS FROM "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON TABLES FROM "anon";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON TABLES FROM "authenticated";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" REVOKE ALL ON TABLES FROM "service_role";

CREATE TABLE "public"."adherence_log" (
  "id"                       integer                  GENERATED ALWAYS AS IDENTITY NOT NULL,
  "prescription_medicine_id" integer,
  "schedule_id"              integer,
  "status"                   text,
  "created_at"               timestamp with time zone DEFAULT now(),
  CONSTRAINT "adherence_log_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."adherence_log"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."caregiver_patients" (
  "id"           integer                  GENERATED ALWAYS AS IDENTITY NOT NULL,
  "caregiver_id" integer                  NOT NULL,
  "patient_id"   integer                  NOT NULL,
  "created_at"   timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "caregiver_patient_unique" UNIQUE (caregiver_id, patient_id),
  CONSTRAINT "caregiver_patients_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."caregiver_patients"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."caregivers" (
  "id"           integer GENERATED ALWAYS AS IDENTITY NOT NULL,
  "name"         text    NOT NULL,
  "phone"        text,
  "email"        text,
  "auth_user_id" uuid,
  CONSTRAINT "caregivers_auth_user_id_unique" UNIQUE (auth_user_id),
  CONSTRAINT "caregivers_email_key" UNIQUE (email),
  CONSTRAINT "caregivers_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."caregivers"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."compartments" (
  "id"                       integer GENERATED ALWAYS AS IDENTITY NOT NULL,
  "slot_number"              integer NOT NULL,
  "pill_count"               integer DEFAULT 0,
  "patient_id"               integer NOT NULL,
  "prescription_medicine_id" integer NOT NULL,
  CONSTRAINT "check_pill_count" CHECK ((pill_count >= 0)),
  CONSTRAINT "check_slot_number" CHECK (((slot_number >= 1) AND (slot_number <= 12))),
  CONSTRAINT "compartments_medicine_unique" UNIQUE (prescription_medicine_id),
  CONSTRAINT "compartments_patient_slot_unique" UNIQUE (patient_id, slot_number),
  CONSTRAINT "compartments_pill_count_check" CHECK ((pill_count >= 0)),
  CONSTRAINT "compartments_pkey" PRIMARY KEY (id),
  CONSTRAINT "compartments_slot_number_check" CHECK (((slot_number >= 1) AND (slot_number <= 12))),
  CONSTRAINT "unique_slot_number" UNIQUE (slot_number)
);

ALTER TABLE "public"."compartments"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."patients" (
  "id"             integer GENERATED ALWAYS AS IDENTITY NOT NULL,
  "name"           text    NOT NULL,
  "phone"          text,
  "fingerprint_id" integer,
  CONSTRAINT "patients_fingerprint_id_key" UNIQUE (fingerprint_id),
  CONSTRAINT "patients_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."patients"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."prescription_medicines" (
  "id"              integer GENERATED ALWAYS AS IDENTITY NOT NULL,
  "prescription_id" integer NOT NULL,
  "med_name"        text    NOT NULL,
  "dosage"          text,
  "frequency"       text,
  "duration"        text,
  CONSTRAINT "prescription_medicines_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."prescription_medicines"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."prescriptions" (
  "id"         integer                     GENERATED ALWAYS AS IDENTITY NOT NULL,
  "patient_id" integer                     NOT NULL,
  "image_path" text,
  "created_at" timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "prescriptions_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."prescriptions"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."schedules" (
  "id"                       integer                GENERATED ALWAYS AS IDENTITY NOT NULL,
  "prescription_medicine_id" integer                NOT NULL,
  "compartment_id"           integer                NOT NULL,
  "start_date"               date                   NOT NULL,
  "end_date"                 date                   NOT NULL,
  "med_time"                 time without time zone NOT NULL,
  CONSTRAINT "check_schedule_dates" CHECK ((end_date >= start_date)),
  CONSTRAINT "schedules_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."schedules"
  ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON SEQUENCE "public"."adherence_log_id_seq" FROM "anon";

REVOKE ALL ON SEQUENCE "public"."adherence_log_id_seq" FROM "authenticated";

REVOKE ALL ON SEQUENCE "public"."caregiver_patients_id_seq" FROM "anon";

REVOKE ALL ON SEQUENCE "public"."caregiver_patients_id_seq" FROM "authenticated";

REVOKE ALL ON SEQUENCE "public"."caregiver_patients_id_seq" FROM "service_role";

REVOKE ALL ON SEQUENCE "public"."caregivers_id_seq" FROM "anon";

REVOKE ALL ON SEQUENCE "public"."caregivers_id_seq" FROM "authenticated";

REVOKE ALL ON SEQUENCE "public"."compartments_id_seq" FROM "anon";

REVOKE ALL ON SEQUENCE "public"."compartments_id_seq" FROM "authenticated";

REVOKE ALL ON SEQUENCE "public"."patients_id_seq" FROM "anon";

REVOKE ALL ON SEQUENCE "public"."patients_id_seq" FROM "authenticated";

REVOKE ALL ON SEQUENCE "public"."prescription_medicines_id_seq" FROM "anon";

REVOKE ALL ON SEQUENCE "public"."prescription_medicines_id_seq" FROM "authenticated";

REVOKE ALL ON SEQUENCE "public"."prescriptions_id_seq" FROM "anon";

REVOKE ALL ON SEQUENCE "public"."prescriptions_id_seq" FROM "authenticated";

REVOKE ALL ON SEQUENCE "public"."schedules_id_seq" FROM "anon";

REVOKE ALL ON SEQUENCE "public"."schedules_id_seq" FROM "authenticated";

CREATE OR REPLACE FUNCTION public.rls_auto_enable()
  RETURNS event_trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'pg_catalog'
  AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION "public"."rls_auto_enable"() FROM "anon", "authenticated", "service_role";

ALTER TABLE "public"."caregivers"
  ADD CONSTRAINT "caregivers_auth_user_id_fkey" FOREIGN KEY (auth_user_id) REFERENCES auth.users(id);

ALTER TABLE "public"."caregiver_patients"
  ADD CONSTRAINT "caregiver_patients_caregiver_fkey" FOREIGN KEY (caregiver_id) REFERENCES public.caregivers(id) ON DELETE CASCADE;

ALTER TABLE "public"."caregiver_patients"
  ADD CONSTRAINT "caregiver_patients_patient_fkey" FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE CASCADE;

ALTER TABLE "public"."compartments"
  ADD CONSTRAINT "compartments_patient_id_fkey" FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE CASCADE;

ALTER TABLE "public"."adherence_log"
  ADD CONSTRAINT "adherence_log_prescription_medicine_id_fkey" FOREIGN KEY (prescription_medicine_id) REFERENCES public.prescription_medicines(id);

ALTER TABLE "public"."compartments"
  ADD CONSTRAINT "compartments_prescription_medicine_id_fkey" FOREIGN KEY (prescription_medicine_id) REFERENCES public.prescription_medicines(id) ON DELETE CASCADE;

ALTER TABLE "public"."prescriptions"
  ADD CONSTRAINT "prescriptions_patient_id_fkey" FOREIGN KEY (patient_id) REFERENCES public.patients(id);

ALTER TABLE "public"."prescription_medicines"
  ADD CONSTRAINT "prescription_medicines_prescription_id_fkey" FOREIGN KEY (prescription_id) REFERENCES public.prescriptions(id);

ALTER TABLE "public"."schedules"
  ADD CONSTRAINT "schedules_compartment_id_fkey" FOREIGN KEY (compartment_id) REFERENCES public.compartments(id);

ALTER TABLE "public"."adherence_log"
  ADD CONSTRAINT "adherence_log_schedule_id_fkey" FOREIGN KEY (schedule_id) REFERENCES public.schedules(id);

ALTER TABLE "public"."schedules"
  ADD CONSTRAINT "schedules_prescription_medicine_id_fkey" FOREIGN KEY (prescription_medicine_id) REFERENCES public.prescription_medicines(id);

CREATE EVENT TRIGGER "ensure_rls"
  ON ddl_command_end
  WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  EXECUTE FUNCTION "public"."rls_auto_enable"();

GRANT EXECUTE ON FUNCTION "public"."rls_auto_enable"() TO PUBLIC;

REVOKE ALL ON FUNCTION "public"."rls_auto_enable"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."rls_auto_enable"() TO "postgres";

REVOKE ALL ON SEQUENCE "public"."adherence_log_id_seq" FROM "service_role";

GRANT SELECT, USAGE ON SEQUENCE "public"."adherence_log_id_seq" TO "service_role";

REVOKE ALL ON SEQUENCE "public"."caregivers_id_seq" FROM "service_role";

GRANT SELECT, USAGE ON SEQUENCE "public"."caregivers_id_seq" TO "service_role";

REVOKE ALL ON SEQUENCE "public"."compartments_id_seq" FROM "service_role";

GRANT SELECT, USAGE ON SEQUENCE "public"."compartments_id_seq" TO "service_role";

REVOKE ALL ON SEQUENCE "public"."patients_id_seq" FROM "service_role";

GRANT SELECT, USAGE ON SEQUENCE "public"."patients_id_seq" TO "service_role";

REVOKE ALL ON SEQUENCE "public"."prescription_medicines_id_seq" FROM "service_role";

GRANT SELECT, USAGE ON SEQUENCE "public"."prescription_medicines_id_seq" TO "service_role";

REVOKE ALL ON SEQUENCE "public"."prescriptions_id_seq" FROM "service_role";

GRANT SELECT, USAGE ON SEQUENCE "public"."prescriptions_id_seq" TO "service_role";

REVOKE ALL ON SEQUENCE "public"."schedules_id_seq" FROM "service_role";

GRANT SELECT, USAGE ON SEQUENCE "public"."schedules_id_seq" TO "service_role";

REVOKE ALL ON TABLE "public"."adherence_log" FROM "anon";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."adherence_log" TO "anon";

REVOKE ALL ON TABLE "public"."adherence_log" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."adherence_log" TO "authenticated";

REVOKE ALL ON TABLE "public"."adherence_log" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."adherence_log" TO "postgres";

REVOKE ALL ON TABLE "public"."adherence_log" FROM "service_role";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."adherence_log" TO "service_role";

REVOKE ALL ON TABLE "public"."caregiver_patients" FROM "anon";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."caregiver_patients" TO "anon";

REVOKE ALL ON TABLE "public"."caregiver_patients" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."caregiver_patients" TO "authenticated";

REVOKE ALL ON TABLE "public"."caregiver_patients" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."caregiver_patients" TO "postgres";

REVOKE ALL ON TABLE "public"."caregiver_patients" FROM "service_role";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."caregiver_patients" TO "service_role";

REVOKE ALL ON TABLE "public"."caregivers" FROM "anon";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."caregivers" TO "anon";

REVOKE ALL ON TABLE "public"."caregivers" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."caregivers" TO "authenticated";

REVOKE ALL ON TABLE "public"."caregivers" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."caregivers" TO "postgres";

REVOKE ALL ON TABLE "public"."caregivers" FROM "service_role";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."caregivers" TO "service_role";

REVOKE ALL ON TABLE "public"."compartments" FROM "anon";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."compartments" TO "anon";

REVOKE ALL ON TABLE "public"."compartments" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."compartments" TO "authenticated";

REVOKE ALL ON TABLE "public"."compartments" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."compartments" TO "postgres";

REVOKE ALL ON TABLE "public"."compartments" FROM "service_role";

GRANT INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."compartments" TO "service_role";

REVOKE ALL ON TABLE "public"."patients" FROM "anon";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."patients" TO "anon";

REVOKE ALL ON TABLE "public"."patients" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."patients" TO "authenticated";

REVOKE ALL ON TABLE "public"."patients" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."patients" TO "postgres";

REVOKE ALL ON TABLE "public"."patients" FROM "service_role";

GRANT MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."patients" TO "service_role";

REVOKE ALL ON TABLE "public"."prescription_medicines" FROM "anon";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."prescription_medicines" TO "anon";

REVOKE ALL ON TABLE "public"."prescription_medicines" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."prescription_medicines" TO "authenticated";

REVOKE ALL ON TABLE "public"."prescription_medicines" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."prescription_medicines" TO "postgres";

REVOKE ALL ON TABLE "public"."prescription_medicines" FROM "service_role";

GRANT INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."prescription_medicines" TO "service_role";

REVOKE ALL ON TABLE "public"."prescriptions" FROM "anon";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."prescriptions" TO "anon";

REVOKE ALL ON TABLE "public"."prescriptions" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."prescriptions" TO "authenticated";

REVOKE ALL ON TABLE "public"."prescriptions" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."prescriptions" TO "postgres";

REVOKE ALL ON TABLE "public"."prescriptions" FROM "service_role";

GRANT INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE ON TABLE "public"."prescriptions" TO "service_role";

REVOKE ALL ON TABLE "public"."schedules" FROM "anon";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."schedules" TO "anon";

REVOKE ALL ON TABLE "public"."schedules" FROM "authenticated";

GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLE "public"."schedules" TO "authenticated";

REVOKE ALL ON TABLE "public"."schedules" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."schedules" TO "postgres";

REVOKE ALL ON TABLE "public"."schedules" FROM "service_role";

GRANT INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."schedules" TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLES TO "anon";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLES TO "authenticated";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT MAINTAIN, REFERENCES, TRIGGER, TRUNCATE ON TABLES TO "service_role";

