import { useEffect, useState } from "react";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { Lock } from "lucide-react";
import { toast } from "sonner";
import { errorMessage } from "@/lib/api";
import { db, isBackendConfigured } from "@/lib/supabaseClient";
import { updatePassword } from "@/lib/auth-api";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Form,
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form";
import { AuthShell } from "@/routes/login";

export const Route = createFileRoute("/reset-password")({
  head: () => ({
    meta: [
      { title: "Choose a New Password — PINDI CRUST" },
      { name: "description", content: "Set a new password for your PINDI CRUST account." },
      { property: "og:title", content: "Choose a New Password — PINDI CRUST" },
      { property: "og:description", content: "Set a new password for your PINDI CRUST account." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: ResetPasswordPage,
});

const schema = z
  .object({
    password: z.string().min(6, "Password must be at least 6 characters"),
    confirm: z.string(),
  })
  .refine((v) => v.password === v.confirm, { message: "Passwords don't match", path: ["confirm"] });
type FormValues = z.infer<typeof schema>;

function ResetPasswordPage() {
  const navigate = useNavigate();
  // The reset email link signs the person in with a short-lived recovery session.
  const [status, setStatus] = useState<"checking" | "ready" | "invalid">("checking");
  const form = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { password: "", confirm: "" },
  });

  useEffect(() => {
    if (!isBackendConfigured) { setStatus("invalid"); return; }
    const { data: sub } = db().auth.onAuthStateChange((event, session) => {
      if (event === "PASSWORD_RECOVERY" || (session && event === "SIGNED_IN")) setStatus("ready");
    });
    void db().auth.getSession().then(({ data }) => {
      setStatus((s) => (data.session ? "ready" : s === "checking" ? "invalid" : s));
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  const onSubmit = async (values: FormValues) => {
    try {
      await updatePassword(values.password);
      toast.success("Password updated. You're signed in.");
      navigate({ to: "/" });
    } catch (err) {
      toast.error(errorMessage(err));
    }
  };

  return (
    <AuthShell
      title="Choose a new password"
      subtitle="Pick something you haven't used before."
      footer={
        <p className="text-center text-sm text-muted-foreground">
          <Link to="/login" className="font-semibold text-primary hover:underline">
            Back to sign in
          </Link>
        </p>
      }
    >
      {status === "checking" && <p className="text-sm text-muted-foreground">Checking your link…</p>}
      {status === "invalid" && (
        <div className="space-y-3 text-sm">
          <p className="text-muted-foreground">
            This reset link is invalid or has expired. Open the newest email on the same device and
            browser you requested it from, or request a new link.
          </p>
          <Button asChild variant="outline" className="w-full">
            <Link to="/forgot-password">Send a new link</Link>
          </Button>
        </div>
      )}
      {status === "ready" && (
        <Form {...form}>
          <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
            {(["password", "confirm"] as const).map((name) => (
              <FormField
                key={name}
                control={form.control}
                name={name}
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>{name === "password" ? "New password" : "Confirm new password"}</FormLabel>
                    <FormControl>
                      <div className="relative">
                        <Lock className="absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground" />
                        <Input type="password" placeholder="••••••••" className="pl-9" {...field} />
                      </div>
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
            ))}
            <Button type="submit" className="w-full" disabled={form.formState.isSubmitting}>
              {form.formState.isSubmitting ? "Saving…" : "Save new password"}
            </Button>
          </form>
        </Form>
      )}
    </AuthShell>
  );
}
