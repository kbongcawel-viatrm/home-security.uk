# Minimum Viable Product Pipeline

This pipeline reduces the current security lab to a small, repeatable local deployment that demonstrates one useful security workflow. The full stack should be expanded only after this path works for a new operator.

## MVP outcome

A new operator can follow one guide on a supported Linux host, start the selected services, produce and find one documented security event, stop the stack safely, and understand how to recover its data.

## Work steps

1. **Define the MVP boundary.** Choose the supported host environment, minimum resource requirements, selected Compose profiles and services, and the specific security outcome the MVP will demonstrate. Treat this as a single-host local lab; do not assume the `all` profile is the MVP.

2. **Make first-run setup safe and clear.** Review `.env.example` and identify values that operators must replace. Document prerequisites, host changes, exposed ports, service access, and any privileged capabilities. Align the README's setup and shutdown instructions with the scripts and Compose configuration.

3. **Select the smallest useful service set.** Include only what is needed to deliver the chosen outcome. Defer host-network sensors, broad vulnerability scanning, automated containment, and Docker-socket-based automation unless they are essential to the workflow and can be operated safely in an authorized lab.

4. **Complete one security workflow end to end.** For example, enroll one test endpoint, generate a known test event, verify it appears in the selected dashboard, and document how an operator investigates it. Identify and resolve missing telemetry or integration paths before describing the workflow as supported.

5. **Document operation and recovery.** Give exact startup and shutdown commands, expected startup time and resource needs, dashboard URLs, initial credential or bootstrap steps, troubleshooting guidance, and backup and restore procedures for the chosen services.

6. **Align monitoring with the MVP.** Reconcile `The Eyes/Uptime-Kuma/monitors.yml` with the selected services and their actual endpoints. Explain how monitors are provisioned or synchronized on a clean installation.

7. **Create a repeatable validation checklist.** Specify checks for Compose configuration, shell syntax, service health, the demonstrated security workflow, and backup and restore. Record the checks actually performed for each MVP change or release.

8. **Align the project documentation and claims.** Update the docs site and project entry points with the current MVP setup path. Distinguish implemented and verified behavior from placeholders, planned integrations, and capabilities that have not been tested end to end.

9. **Expand in validated increments.** Once the MVP path is repeatable, add capabilities such as network detection, vulnerability scanning, incident response automation, secrets rotation, and LLM assessment one at a time. Document prerequisites and validation for each addition.

## MVP completion criteria

- A new operator can configure and start the selected services by following the current documentation.
- The documented test event can be generated and found in the expected dashboard.
- The operator can stop the stack safely and follow documented data recovery steps.
- The selected services, endpoints, prerequisites, and limitations are described consistently across the README and docs.
- The validation checklist has been run and its results recorded.
