from fastapi import APIRouter, Depends
from pydantic import BaseModel

from app.authn import get_actor_user_id
from app.authz import require_admin
from app.db import USERS
from app.services.roles import RoleService

router = APIRouter()


class RolePatchRequest(BaseModel):
    role: str


@router.get("/{user_id}")
def get_user(user_id: int):
    user = USERS.get(user_id)
    if user is None:
        return {"error": "not_found"}
    return {"id": user.id, "email": user.email, "role": user.role}


@router.patch("/{user_id}/role")
def patch_user_role(
    user_id: int,
    payload: RolePatchRequest,
    actor_user_id: int = Depends(get_actor_user_id),
):
    require_admin(actor_user_id)
    return RoleService.update_user_role(
        actor_user_id=actor_user_id,
        target_user_id=user_id,
        role=payload.role,
    )
