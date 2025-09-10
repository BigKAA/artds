2# Project Overview

This project is a Helm chart for deploying a [389 Directory Server](https://www.port389.org/) on Kubernetes. The 389 Directory Server is a full-featured LDAPv3-compliant server. This Helm chart simplifies the process of deploying and configuring a 389ds instance in a Kubernetes cluster.

## Key Technologies

*   **Kubernetes:** The container orchestration platform for deploying and managing the 389ds instance.
*   **Helm:** The package manager for Kubernetes, used to define, install, and upgrade the 389ds application.
*   **Docker:** The containerization technology used to package the 389ds application.
*   **389 Directory Server:** The LDAP server implementation.

## Architecture

The Helm chart deploys the following Kubernetes resources:

*   **StatefulSet:** Manages the 389ds pods, ensuring stable and unique network identifiers and persistent storage.
*   **Services:** Expose the LDAP and LDAPS ports to other applications within the cluster or externally.
*   **PersistentVolumeClaim:** Provides persistent storage for the LDAP data.
*   **Secrets:** Store sensitive data, such as the Directory Manager password.
*   **ConfigMaps:** Store configuration data, such as LDIF files for initial schema and data.
*   **Jobs:** Perform initial setup and configuration of the 389ds instance.

## Building and Running

This is a Helm chart, so it's not "built" in the traditional sense. To deploy the chart, you will need to have Helm installed and configured to connect to your Kubernetes cluster.

### Prerequisites

*   Helm 3
*   A running Kubernetes cluster
*   `kubectl` configured to connect to your cluster

### Deployment Steps

1.  **Customize the configuration:** Modify the `artds/values.yaml` file to suit your environment. This includes setting the storage class, replica count, and other parameters.

2.  **Install the chart:** Run the following command from the root of the project:

    ```bash
    helm install <release-name> ./artds -f ./artds/values.yaml
    ```

    Replace `<release-name>` with a name for your deployment.

### TODO

*   Add instructions for running tests.

## Development Conventions

*   The Helm chart follows the standard directory structure.
*   The `artds/values.yaml` file is the single source of truth for configuration.
*   Templates are located in the `artds/templates` directory.
*   The `_helpers.tpl` file contains helper templates and functions used by other templates.
