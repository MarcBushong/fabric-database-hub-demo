# syntax=docker/dockerfile:1
# Local, containerized runs of the workload runner (ADR 0010), for example against the SQL Server 2022 container in
# compose.yaml. Build from the repository root, because the runner embeds scenarios/ and database/common/:
#   docker build --file workload-generator/Dockerfile --tag contosocare-workload .
# Base images are updated by Dependabot.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY workload-generator/global.json workload-generator/Directory.Build.props workload-generator/Directory.Packages.props workload-generator/
COPY workload-generator/src/ContosoCare.Workload/ContosoCare.Workload.csproj workload-generator/src/ContosoCare.Workload/packages.lock.json workload-generator/src/ContosoCare.Workload/
WORKDIR /src/workload-generator
RUN dotnet restore src/ContosoCare.Workload/ContosoCare.Workload.csproj --locked-mode
COPY scenarios/ /src/scenarios/
COPY database/common/ /src/database/common/
COPY workload-generator/src/ src/
RUN dotnet publish src/ContosoCare.Workload/ContosoCare.Workload.csproj --configuration Release --no-restore --output /app

# The default (Debian) runtime image includes ICU, which Microsoft.Data.SqlClient needs; chiseled images don't.
FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final
WORKDIR /app
COPY --from=build /app ./
# Run as the non-root user that the .NET images define.
USER $APP_UID
ENTRYPOINT ["dotnet", "ContosoCare.Workload.dll"]
CMD ["--help"]