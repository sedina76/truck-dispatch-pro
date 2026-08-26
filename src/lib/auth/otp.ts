// Auth OTP length mismatch repair -- the actual length Supabase Auth
// issues for a "signup" confirmation code is a project-level Dashboard
// setting (Authentication -> Emails -> OTP length), NOT something this
// app can query at runtime -- it's baked into the {{ .Token }} value the
// "Confirm signup" email template renders. Confirmed live: this project's
// current Dashboard setting produces an 8-digit code, not Supabase's
// 6-digit default. One shared constant, imported by both the client OTP
// form and the server action that validates it, so the two can never
// silently drift apart again the way the original 6-digit assumption did.
//
// If this project's Dashboard OTP-length setting is ever changed, this is
// the one place to update -- everything else derives from it.
export const SIGNUP_OTP_LENGTH = 8;
