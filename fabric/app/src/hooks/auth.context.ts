import { createContext, useContext } from "react";
import type { OpaqueSession } from "@microsoft/rayfin-auth";

export interface AuthContextValue {
    session: OpaqueSession | null;
    isAuthenticated: boolean;
    isLoading: boolean;
    signIn: () => void;
    signOut: () => void;
    isSigningIn: boolean;
    signInError: string | null;
}

export const AuthContext = createContext<AuthContextValue | undefined>(undefined);

export function useAuth(): AuthContextValue {
    const context = useContext(AuthContext);
    if (context === undefined) {
        throw new Error("useAuth must be used within an AuthProvider");
    }
    return context;
}
