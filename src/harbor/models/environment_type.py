from enum import Enum


class EnvironmentType(str, Enum):
    DOCKER = "docker"
    PODMAN_HPC = "podman_hpc"
    DAYTONA = "daytona"
    E2B = "e2b"
    MODAL = "modal"
    RUNLOOP = "runloop"
    GKE = "gke"
    APPTAINER = "apptainer"
    APPTAINER_BRIDGE = "apptainer_bridge"
    BEAM = "beam"
    APPLE_CONTAINER = "apple-container"
