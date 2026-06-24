FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

ARG REPO_URL
ARG BRANCH=master
ARG GIT_TOKEN

WORKDIR /src
RUN echo "REPO_URL=[${REPO_URL}] BRANCH=[${BRANCH}] GIT_TOKEN=[${GIT_TOKEN}]"
RUN git clone --branch ${BRANCH} --depth 1 \
    http://${GIT_TOKEN}@${REPO_URL#http://} .

RUN dotnet publish FarmameTerms/FarmameTerms.csproj -c Release -o /app/out && ls /app/out

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app/out .
ENTRYPOINT ["dotnet", "FarmameTerms.dll"]