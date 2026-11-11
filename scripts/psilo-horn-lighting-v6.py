"""Preserve Psilo's lighting while excluding its horns from three fill lights.

Only light-receiver rules change. Energies, materials, World, key/rim lighting
and shadow-blocker rules are untouched. Existing include/exclude collections
are shallow-copied so other lights sharing them are not changed. Their entries
stay intact, and an additional excluded child collection subtracts the horns.
This also preserves an include-only receiver set such as Pedestal-only bounce.

Blender's include-minus-exclude semantics:
https://docs.blender.org/manual/en/latest/render/lights/light_linking.html
"""
import bpy

_FILL_NAMES = ('STUDIO_BodyBounce', 'STUDIO_LowFill', 'STUDIO_Fill')
_OWNER_TAG = 'psilo_horn_fill_v6'
_EXCLUDE_TAG = 'psilo_horn_fill_exclusions_v6'


def apply_horn_lighting_v6(scene):
    """Exclude Horn_L/R without expanding any existing receiver collection."""
    horns = [scene.objects.get(name) for name in ('Horn_L', 'Horn_R')]
    if any(horn is None for horn in horns):
        raise ValueError('Horn_L and Horn_R are required before lighting setup.')
    result = []
    for name in _FILL_NAMES:
        emitter = scene.objects.get(name)
        if emitter is None:
            continue
        previous = emitter.light_linking.receiver_collection
        if previous is not None and previous.get(_OWNER_TAG) == name:
            receivers = previous
        else:
            receivers = previous.copy() if previous else bpy.data.collections.new(name + ' receivers')
            receivers.name = name + ' receivers without Psilo horns'
            receivers[_OWNER_TAG] = name
            receivers['psilo_original_receiver_collection'] = previous.name if previous else ''
            emitter.light_linking.receiver_collection = receivers

        excluded = next((child for child in receivers.children
                         if child.get(_EXCLUDE_TAG) == name), None)
        if excluded is None:
            excluded = bpy.data.collections.new(name + ' excluded Psilo horns')
            excluded[_EXCLUDE_TAG] = name
            receivers.children.link(excluded)
        # Keep this private subtraction set exact if horn meshes were rebuilt.
        for obj in list(excluded.objects):
            if obj not in horns:
                excluded.objects.unlink(obj)
        for horn in horns:
            if horn.name not in excluded.objects:
                excluded.objects.link(horn)
        excluded_index = next(index for index, child in enumerate(receivers.children)
                              if child == excluded)
        receivers.collection_children[excluded_index].light_linking.link_state = 'EXCLUDE'

        # Do not replace or flip existing positive entries. An include-only set
        # containing just a horn must become empty, not expand to all objects.
        result.append({
            'light': name,
            'original_receiver_collection': receivers['psilo_original_receiver_collection'],
            'receiver_collection': receivers.name,
            'excluded_horns': [horn.name for horn in horns],
            'existing_rules_preserved': True,
            'energy_unchanged': float(emitter.data.energy),
        })
    scene.view_layers[0].update()
    return {'fill_light_links': result, 'other_lighting_changed': False}
