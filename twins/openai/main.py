from fastapi import FastAPI

from shared.control import ControlPlane, create_control_router

app = FastAPI()
control = ControlPlane()
app.include_router(create_control_router(control))
