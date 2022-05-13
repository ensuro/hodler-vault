from invoke import Collection
from py_docker_k8s_tasks import docker_tasks
from py_docker_k8s_tasks.util_tasks import add_tasks

ns = Collection()
add_tasks(ns, docker_tasks)
