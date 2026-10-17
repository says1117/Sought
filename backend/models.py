"""Shared API response models; endpoint models are added with their routes."""
from typing import Literal

from pydantic import BaseModel


class HealthResponse(BaseModel):
    ok: Literal[True] = True
    schema_version: Literal[1] = 1
