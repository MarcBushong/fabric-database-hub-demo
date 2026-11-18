import { Button } from "@fluentui/react-components";

export const ErrorFallback = ({ error, resetErrorBoundary }: { error: unknown; resetErrorBoundary: () => void }) => {
    const message = error instanceof Error ? error.message : String(error);
    if (import.meta.env.DEV) console.error("[ErrorBoundary]", error);
    return (
        <div className="gate" role="alert">
            <section className="gate-card">
                <p className="muted">Database Hub Insights</p>
                <h1>Something went wrong</h1>
                <pre className="dax">{message}</pre>
                <div>
                    <Button appearance="primary" onClick={resetErrorBoundary}>
                        Try again
                    </Button>
                </div>
            </section>
        </div>
    );
};
