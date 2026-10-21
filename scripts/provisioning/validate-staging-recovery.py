"""Recovery restricted to an inactive partial staging-replica-01."""
import argparse
import json
import os


def validate(kind, data):
    if kind == 'pool':
        if data.get('success') is not True:
            raise ValueError('Cloudflare pool request failed')
        origins = data.get('result', {}).get('origins')
        if not isinstance(origins, list):
            raise ValueError('Invalid pool origins')
        primary = [o for o in origins if o.get('name') == 'staging-primary']
        if len(primary) != 1 or primary[0].get('address') != os.environ.get('TF_PRIMARY_INSTANCE_IPV4') or primary[0].get('enabled', True) is not True:
            raise ValueError('Enabled primary must match configured primary address')
        if any(str(o.get('name', '')).startswith('staging-replica-') for o in origins):
            raise ValueError('Replica endpoints remain in Cloudflare; use normal draining instead')
        print('Primary verified; no staging replica endpoint exists in the pool.')
    elif kind == 'plan':
        if data.get('errored') is True or data.get('complete') is False or data.get('deferred_changes'):
            raise ValueError('Incomplete recovery plan')
        allowed = {
            f'module.replica["staging-replica-01"].openstack_compute_{resource}_v2.instance'
            for resource in ('keypair', 'instance')
        }
        changed = []
        for resource in data.get('resource_changes', []):
            actions = resource.get('change', {}).get('actions')
            if actions in (['no-op'], ['read']):
                continue
            if resource['address'] not in allowed or actions != ['delete']:
                raise ValueError('Plan changes resources beyond partial staging replica cleanup')
            changed.append(resource['address'])
        outputs = data.get('planned_values', {}).get('outputs', {})
        if outputs.get('replica_count', {}).get('value') != 0 or outputs.get('replica_names', {}).get('value') != [] or outputs.get('replica_ipv4', {}).get('value') != []:
            raise ValueError('Plan does not end with zero replicas')
        print('### Staging replica reconciliation')
        print('Only deletion of staging-replica-01 resources is allowed; no Cloudflare or primary modification.')
        for address in changed:
            print('- Delete `' + address + '`')
        if not changed:
            print('- No infrastructure mutation; reconcile outputs only.')
    elif kind == 'outputs':
        if data.get('replica_count', {}).get('value') != 0 or data.get('replica_names', {}).get('value') != [] or data.get('replica_ipv4', {}).get('value') != []:
            raise ValueError('State does not report zero replicas')
        print('Verified: state reports zero replicas.')


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('kind', choices=['pool', 'plan', 'outputs'])
    p.add_argument('file')
    args = p.parse_args()
    validate(args.kind, json.load(open(args.file)))
