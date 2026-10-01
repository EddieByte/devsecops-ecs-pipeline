# ──────────────────────────────────────────────────────────────────────────────
# Dockerfile — Spring PetClinic, Java 17 Multi-stage Build
#
# Stage 1 (builder): Compiles the Maven project and produces an executable JAR.
# Stage 2 (runtime): Runs the JAR on a minimal JRE 17 image.
#
# PetClinic uses Spring Boot's embedded Tomcat — no external Tomcat needed.
# The JAR is self-contained and started directly with `java -jar`.
# ──────────────────────────────────────────────────────────────────────────────

# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM eclipse-temurin:17-jdk-jammy AS builder

LABEL stage="builder"

WORKDIR /build

# Copy dependency manifest first to exploit Docker layer caching.
# Dependencies are only re-downloaded when pom.xml changes.
COPY pom.xml .

# Install Maven (Temurin image does not bundle it)
ARG MAVEN_VERSION=3.9.6
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends curl && \
    curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
      -o /tmp/maven.tar.gz && \
    tar -xzf /tmp/maven.tar.gz -C /opt && \
    ln -s "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn && \
    rm /tmp/maven.tar.gz && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Pre-fetch dependencies (layer cached unless pom.xml changes)
RUN mvn dependency:go-offline -B --no-transfer-progress 2>/dev/null || true

# Copy source and build — tests run in the CI quality gate job, skip here
COPY src ./src
RUN mvn clean package -DskipTests -B --no-transfer-progress

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
# Use JRE-only image — smaller surface area, no compiler toolchain at runtime.
FROM eclipse-temurin:17-jre-jammy AS runtime

LABEL maintainer="devops@example.com" \
      org.opencontainers.image.title="spring-petclinic" \
      org.opencontainers.image.description="Spring PetClinic on Java 17 / Embedded Tomcat" \
      org.opencontainers.image.base.name="eclipse-temurin:17-jre-jammy"

WORKDIR /app

# Copy only the built JAR from the builder stage
# finalName in pom.xml is "spring-petclinic" — produces spring-petclinic.jar
COPY --from=builder /build/target/spring-petclinic.jar app.jar

# Expose the port Spring Boot listens on (matches ECS task definition containerPort)
EXPOSE 8080

# Drop to a non-root user for container hygiene
RUN groupadd --system appgroup && \
    useradd  --system --gid appgroup --no-create-home appuser && \
    chown -R appuser:appgroup /app

USER appuser

# JVM tuning for a t3.small container:
#   -XX:+UseContainerSupport   — honours cgroup memory limits
#   -XX:MaxRAMPercentage=75.0  — uses up to 75% of the 2GiB task memory
#   -Djava.security.egd        — faster SecureRandom startup
ENTRYPOINT ["java", \
  "-XX:+UseContainerSupport", \
  "-XX:MaxRAMPercentage=75.0", \
  "-Djava.security.egd=file:/dev/./urandom", \
  "-jar", "app.jar"]
