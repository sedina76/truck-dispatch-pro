// The length Supabase Auth issues for a "signup" confirmation code is a
// project-level Dashboard setting ("Email OTP Length" under Authentication),
// NOT something this app can query at runtime -- it's baked into the
// {{ .Token }} value the "Confirm signup" email template renders. This
// project is standardised on Supabase Auth's own default of 6 digits.
//
// One shared constant, imported by both the client OTP form and the server
// action that validates it, so the two can never silently drift apart. If
// the Dashboard "Email OTP Length" is ever changed, this is the one place
// to update in code -- the regex, the error copy, the number of OTP boxes,
// the submit-enable check and the aria-label all derive from it. The
// application constant and the Dashboard setting MUST always agree, or a
// real signup code will be rejected.
export const SIGNUP_OTP_LENGTH = 6;
