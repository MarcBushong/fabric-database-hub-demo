export const ErrorFallback = ({ error, resetErrorBoundary }: { error: unknown; resetErrorBoundary: () => void }) => {
    const message = error instanceof Error ? error.message : String(error);
    if (import.meta.env.DEV) console.error("[ErrorBoundary]", error);
    return (
        <div className="gate" role="alert">
            <section className="glass gate-card">
                <p className="eyebrow">Database Hub Insights · preview</p>
                <h1>Something went wrong</h1>
                <pre className="dax">{message}</pre>
                <button type="button" className="btn-primary" onClick={resetErrorBoundary}>
                    Try again
                </button>
            </section>
        </div>
    );
};
