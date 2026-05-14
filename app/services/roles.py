from fastapi import HTTPException

from app.audit import record_role_change
from app.db import USERS


class RoleService:
    @staticmethod
    def update_user_role(*, actor_user_id: int, target_user_id: int, role: str) -> dict:
        target = USERS.get(target_user_id)
        if target is None:
            raise HTTPException(status_code=404, detail="User not found")

        normalized = role.strip().lower()
        if normalized not in {"admin", "member"}:
            raise HTTPException(status_code=422, detail="role must be admin or member")

        old_role = target.role
        if old_role != normalized:
            target.role = normalized
            record_role_change(actor_user_id, target_user_id, old_role, normalized)

        return {
            "id": target.id,
            "email": target.email,
            "role": target.role,
        }
