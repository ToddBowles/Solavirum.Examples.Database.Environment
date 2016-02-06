# README #

### What is this repository for? ###

Contains a relatively simple sample environment that creates a PostgreSQL database using RDS.

This repository was copied and then modified from an internal source. As such, it has not been fully tested and may have issues.

### How do I get set up? ###

* A package containing a the scripts required to create a versioned environment can be built using /scripts/build/build.ps1. This will automatically create a packaged versioned based on the current time.
* The environment can be created by invoking the /src/scripts/environment/Invoke-NewEnvironment.ps1 script and deleted by invoking the /src/scripts/environment/Invoke-DeleteEnvironment.ps1
* Multiple copies of the various Powershell utility scripts are included in the repository due to the poor way in which common functions are handled. This will be improved at a future date.

### Contribution guidelines ###

* The environment creation has a test (which will spin up a self contained temporary environment), but the environment provisioning itself actually contains a smoke test that validates that everything was provisioned successfully.