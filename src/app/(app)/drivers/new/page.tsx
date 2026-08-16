import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { SectionHeading } from "@/components/ui/section-heading";
import { SsnConfirmFields } from "@/components/ui/ssn-confirm-fields";
import { createDriver } from "../actions";

export default async function NewDriverPage() {
  const supabase = await createClient();
  const { data: carriers } = await supabase.from("carriers").select("id, legal_name").order("legal_name");

  return (
    <FormCard
      title="New Driver"
      description="Add a driver to one of your carriers. SSN is encrypted at rest and only ever shown masked afterward; direct deposit numbers are added after creation."
      action={createDriver}
      cancelHref="/drivers"
      submitLabel="Create Driver"
    >
      <FormGrid>
        <SectionHeading title="Employment" description="Which carrier this driver works under." />
        <FormSelect
          label="Carrier"
          name="carrier_id"
          required
          options={(carriers ?? []).map((c) => ({ value: c.id, label: c.legal_name }))}
        />
        <FormSelect
          label="Status"
          name="status"
          defaultValue="active"
          options={[
            { value: "active", label: "Active" },
            { value: "inactive", label: "Inactive" },
            { value: "on_leave", label: "On Leave" },
            { value: "applicant", label: "Applicant" },
            { value: "terminated", label: "Terminated" },
          ]}
        />
        <FormField label="Employee number" name="employee_number" />
        <FormField label="Department" name="department" placeholder="Operations" />
        <FormField label="Hire date" name="hire_date" type="date" />
        <FormField label="Home terminal city" name="home_terminal_city" />
        <FormField label="Home terminal state" name="home_terminal_state" placeholder="IL" />

        <SectionHeading
          title="Personal Information"
          description="Contact and identity details. SSN is encrypted before it ever reaches the database and is never shown in full again -- only the admin PII panel on the driver's profile can request a masked reveal, which is itself logged."
        />
        <FormField label="First name" name="first_name" required />
        <FormField label="Middle name" name="middle_name" />
        <FormField label="Last name" name="last_name" required />
        <FormField label="Date of birth" name="date_of_birth" type="date" />
        <SsnConfirmFields />
        <FormField label="Phone" name="phone" type="tel" />
        <FormField label="Email" name="email" type="email" />
        <FormField label="Address" name="address_line1" />
        <FormField label="City" name="city" />
        <FormField label="State" name="state" placeholder="IL" />
        <FormField label="Postal code" name="postal_code" />
        <FormSelect
          label="Gender"
          name="gender"
          options={[
            { value: "male", label: "Male" },
            { value: "female", label: "Female" },
            { value: "other", label: "Other" },
            { value: "prefer_not_to_say", label: "Prefer not to say" },
          ]}
        />
        <FormField label="Emergency contact name" name="emergency_contact_name" />
        <FormField label="Emergency contact phone" name="emergency_contact_phone" type="tel" />

        <SectionHeading title="License & Medical" description="CDL and DOT medical certification." />
        <FormField label="CDL number" name="cdl_number" />
        <FormField label="CDL state" name="cdl_state" placeholder="IL" />
        <FormSelect
          label="CDL class"
          name="cdl_class"
          options={[
            { value: "A", label: "Class A" },
            { value: "B", label: "Class B" },
            { value: "C", label: "Class C" },
          ]}
        />
        <FormField label="CDL restrictions" name="cdl_restrictions" />
        <FormField label="CDL endorsements" name="cdl_endorsements" placeholder="H, N, T" />
        <FormField label="CDL expiry date" name="cdl_expiry_date" type="date" />
        <FormField label="Medical card number" name="medical_card_number" />
        <FormField label="Medical card expiry date" name="medical_card_expiry_date" type="date" />

        <SectionHeading title="Certifications & Screening" description="Drug testing, background checks, and MVR." />
        <FormField label="Drug test date" name="drug_test_date" type="date" />
        <FormField label="Drug test expiry date" name="drug_test_expiry_date" type="date" />
        <FormField label="Background check date" name="background_check_date" type="date" />
        <FormSelect
          label="Background check status"
          name="background_check_status"
          options={[
            { value: "pending", label: "Pending" },
            { value: "passed", label: "Passed" },
            { value: "failed", label: "Failed" },
          ]}
        />
        <FormField label="MVR date" name="mvr_date" type="date" />
        <FormSelect
          label="MVR status"
          name="mvr_status"
          options={[
            { value: "pending", label: "Pending" },
            { value: "passed", label: "Passed" },
            { value: "failed", label: "Failed" },
          ]}
        />
        <FormField label="TWIC expiry date" name="twic_expiry_date" type="date" />
        <FormField label="Hazmat endorsement expiry date" name="hazmat_endorsement_expiry_date" type="date" />

        <SectionHeading title="Identification & Work Authorization" description="Passport and eligibility to work in the US." />
        <FormField label="Passport number" name="passport_number" />
        <FormField label="Passport expiry date" name="passport_expiry_date" type="date" />
        <FormSelect
          label="Work authorization status"
          name="work_authorization_status"
          options={[
            { value: "citizen", label: "US Citizen" },
            { value: "permanent_resident", label: "Permanent Resident" },
            { value: "visa", label: "Visa" },
            { value: "ead", label: "Employment Authorization Document" },
            { value: "other", label: "Other" },
          ]}
        />
        <FormField label="Work authorization expiry date" name="work_authorization_expiry_date" type="date" />

        <SectionHeading title="Payroll" description="Pay structure. Direct deposit numbers are added after creation." />
        <FormSelect
          label="Pay type"
          name="pay_type"
          options={[
            { value: "per_mile", label: "Per mile" },
            { value: "percentage", label: "Percentage" },
            { value: "hourly", label: "Hourly" },
            { value: "salary", label: "Salary" },
          ]}
        />
        <FormField label="Pay rate" name="pay_rate" type="number" step="0.01" />
        <FormField label="Direct deposit bank name" name="direct_deposit_bank_name" />

        <FormTextarea label="Notes" name="notes" />
      </FormGrid>
    </FormCard>
  );
}
