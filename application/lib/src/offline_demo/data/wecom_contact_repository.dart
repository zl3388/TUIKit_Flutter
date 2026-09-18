import '../domain/models.dart';
import '../domain/repositories.dart';
import '../domain/wecom_directory_models.dart';
import 'wecom_merged_directory_repository.dart';

class WeComContactRepository implements ContactRepository {
  const WeComContactRepository(
    this._directory, {
    required this.currentCorporationId,
  });

  final WeComMergedDirectoryRepository _directory;
  final int currentCorporationId;

  @override
  bool get isAvailable => true;

  @override
  Future<List<OrgUnit>> listOrganizationUnits() async {
    final departments = await _directory.listDepartments(
      corporationId: currentCorporationId,
    );
    final departmentIds =
        departments.map((department) => department.id).toSet();
    final units = departments
        .map(
          (department) => OrgUnit(
            id: department.id.toString(),
            name: department.name,
            parentId: department.parentId == 0 ||
                    !departmentIds.contains(department.parentId)
                ? null
                : department.parentId.toString(),
            sortOrder: department.displayOrder,
          ),
        )
        .toList(growable: false)
      ..sort(_compareOrganizationUnits);
    return List<OrgUnit>.unmodifiable(units);
  }

  @override
  Future<List<DirectoryContact>> listContacts({
    String? organizationUnitId,
  }) async {
    final requestedDepartmentId =
        organizationUnitId == null ? null : int.tryParse(organizationUnitId);
    if (organizationUnitId != null && requestedDepartmentId == null) {
      throw ArgumentError.value(
        organizationUnitId,
        'organizationUnitId',
        'Must be a numeric department ID',
      );
    }
    final results = await Future.wait<Object>([
      _directory.listAllInternalContacts(),
      _directory.listDepartments(corporationId: currentCorporationId),
      _directory.listDepartmentMemberships(),
    ]);
    final contacts = results[0] as List<WeComInternalContact>;
    final departments = results[1] as List<WeComDepartment>;
    final memberships = results[2] as List<WeComDepartmentMembership>;
    final departmentsById = <int, WeComDepartment>{
      for (final department in departments) department.id: department,
    };
    final membershipsByUser = <int, List<WeComDepartmentMembership>>{};
    final requestedUserIds = <int>{};
    for (final membership in memberships) {
      if (!departmentsById.containsKey(membership.departmentId)) {
        continue;
      }
      membershipsByUser
          .putIfAbsent(membership.userId, () => [])
          .add(membership);
      if (membership.departmentId == requestedDepartmentId) {
        requestedUserIds.add(membership.userId);
      }
    }
    for (final userMemberships in membershipsByUser.values) {
      userMemberships.sort(_compareMemberships);
    }

    return contacts
        .where(
      (contact) =>
          requestedDepartmentId == null ||
          requestedUserIds.contains(contact.id),
    )
        .map(
      (contact) {
        final primaryMembership = membershipsByUser[contact.id]?.firstOrNull;
        final department = primaryMembership == null
            ? null
            : departmentsById[primaryMembership.departmentId];
        return DirectoryContact(
          id: contact.id.toString(),
          displayName: contact.displayName,
          account: _nonEmpty(contact.account),
          organizationName: _nonEmpty(contact.externalCorporationName),
          organizationUnitId: department?.id.toString(),
          departmentName: _nonEmpty(department?.name),
          jobTitle:
              _nonEmpty(primaryMembership?.job) ?? _nonEmpty(contact.position),
        );
      },
    ).toList(growable: false);
  }

  static int _compareOrganizationUnits(OrgUnit left, OrgUnit right) {
    final order = left.sortOrder.compareTo(right.sortOrder);
    return order != 0 ? order : left.id.compareTo(right.id);
  }

  static int _compareMemberships(
    WeComDepartmentMembership left,
    WeComDepartmentMembership right,
  ) {
    final mainJob = right.mainJobFlag.compareTo(left.mainJobFlag);
    if (mainJob != 0) {
      return mainJob;
    }
    final order = left.sortOrder.compareTo(right.sortOrder);
    return order != 0 ? order : left.departmentId.compareTo(right.departmentId);
  }

  String? _nonEmpty(String? value) {
    return value == null || value.isEmpty ? null : value;
  }
}
