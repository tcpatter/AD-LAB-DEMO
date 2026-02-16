"""Generate 100 AD users across 6 departments with realistic data using Faker."""

import csv
import json
import os
import random
import string

from faker import Faker

fake = Faker()
Faker.seed(42)
random.seed(42)

DOMAIN = "managed-connections.net"
DOMAIN_DN = "DC=managed-connections,DC=net"
BASE_OU = f"OU=ADLab,{DOMAIN_DN}"
USERS_OU = f"OU=Users,{BASE_OU}"

DEPARTMENTS = ["HR", "IT", "Legal", "Finance", "Marketing", "Operations"]

# Role distribution per department (~16-17 users each):
# Manager: ~2, Employee: ~11-12, Contractor: ~3-4
ROLE_DISTRIBUTION = {
    "Managers": 2,
    "Employees": 11,
    "Contractors": 4,
}

TOTAL_USERS = 100
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")


def generate_password(length: int = 16) -> str:
    """Generate a random password meeting complexity requirements."""
    chars = string.ascii_letters + string.digits + "!@#$%"
    # Ensure at least one of each type
    password = [
        random.choice(string.ascii_uppercase),
        random.choice(string.ascii_lowercase),
        random.choice(string.digits),
        random.choice("!@#$%"),
    ]
    password += [random.choice(chars) for _ in range(length - 4)]
    random.shuffle(password)
    return "".join(password)


def generate_sam_account_name(first_name: str, last_name: str, existing: set) -> str:
    """Generate a unique SamAccountName (first initial + last name, max 20 chars)."""
    base = f"{first_name[0]}{last_name}".lower()
    base = "".join(c for c in base if c.isalnum())[:20]
    sam = base
    counter = 1
    while sam in existing:
        suffix = str(counter)
        sam = f"{base[:20-len(suffix)]}{suffix}"
        counter += 1
    return sam


def generate_users() -> list[dict]:
    """Generate 100 users distributed across departments and roles."""
    users = []
    existing_sams = set()

    # Calculate users per department: 6 depts, 100 users
    # 17 users each for first 4 depts, 16 for last 2 = 100
    dept_counts = []
    base_per_dept = TOTAL_USERS // len(DEPARTMENTS)
    remainder = TOTAL_USERS % len(DEPARTMENTS)
    for i, dept in enumerate(DEPARTMENTS):
        count = base_per_dept + (1 if i < remainder else 0)
        dept_counts.append((dept, count))

    for dept, dept_count in dept_counts:
        # Distribute roles within department
        managers = ROLE_DISTRIBUTION["Managers"]
        contractors = ROLE_DISTRIBUTION["Contractors"]
        employees = dept_count - managers - contractors

        role_assignments = (
            [("Managers", "Manager")] * managers
            + [("Employees", "Employee")] * employees
            + [("Contractors", "Contractor")] * contractors
        )

        for role_ou, role_title in role_assignments:
            first_name = fake.first_name()
            last_name = fake.last_name()
            display_name = f"{first_name} {last_name}"
            sam = generate_sam_account_name(first_name, last_name, existing_sams)
            existing_sams.add(sam)
            upn = f"{sam}@{DOMAIN}"
            ou_path = f"OU={role_ou},OU={dept},{USERS_OU}"
            password = generate_password()

            users.append(
                {
                    "FirstName": first_name,
                    "LastName": last_name,
                    "DisplayName": display_name,
                    "SamAccountName": sam,
                    "UPN": upn,
                    "Department": dept,
                    "Role": role_title,
                    "OUPath": ou_path,
                    "Password": password,
                    "Enabled": "True",
                }
            )

    return users


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    users = generate_users()
    print(f"Generated {len(users)} users")

    # Department summary
    dept_summary = {}
    for u in users:
        key = f"{u['Department']}/{u['Role']}"
        dept_summary[key] = dept_summary.get(key, 0) + 1
    for key in sorted(dept_summary):
        print(f"  {key}: {dept_summary[key]}")

    # Write CSV
    csv_path = os.path.join(OUTPUT_DIR, "users.csv")
    fieldnames = [
        "FirstName",
        "LastName",
        "DisplayName",
        "SamAccountName",
        "UPN",
        "Department",
        "Role",
        "OUPath",
        "Password",
        "Enabled",
    ]
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(users)
    print(f"CSV written to: {csv_path}")

    # Write JSON
    json_path = os.path.join(OUTPUT_DIR, "users.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(users, f, indent=2)
    print(f"JSON written to: {json_path}")


if __name__ == "__main__":
    main()
