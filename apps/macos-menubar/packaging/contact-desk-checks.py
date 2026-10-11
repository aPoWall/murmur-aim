#!/usr/bin/env python3
"""Synthetic full-directory and on-demand history boundary checks; no network or send."""
import importlib.util, json, tempfile, unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('reader',Path(__file__).resolve().parents[1]/'Sources/MurmurMenuBar/Resources/mesh-comms-query.py')
Q=importlib.util.module_from_spec(spec);spec.loader.exec_module(Q)

class ContactDeskTests(unittest.TestCase):
    def test_full_directory_keeps_quiet_contacts_without_grants(self):
        data={'privacy':'owner-metadata','people':[{'id':'person:connected','agents':['agent-demo'],'writable_agents':['agent-demo']}]}
        people={'privacy':'operator_metadata_only_tailnet','observed_at':'2026-10-11T12:00:00Z','people':[{'id':'person:connected'},{'id':'person:quiet','name':'Quiet'},{'id':'person:former','history':True},{'id':'person:private','name':'Hidden'}], 'bindings':[{'person':'person:private','agent':'custom-private'}]}
        share={'privacy':'metadata-only','private_contours':[{'peer_identity':'custom-private','privacy':'status-only'}]}
        result=Q.add_roster(data,people,share)
        self.assertEqual([p['id'] for p in result['people']],['person:connected','person:quiet'])
        self.assertEqual(result['people'][1]['writable_agents'],[])
        self.assertEqual(result['people'][0]['writable_agents'],['agent-demo'])
        self.assertEqual(result['roster_at'],people['observed_at'])

    def test_unsafe_roster_rejected(self):
        with self.assertRaises(ValueError):Q.add_roster({'privacy':'owner-metadata','people':[]},{'privacy':'public'},{'privacy':'metadata-only'})

    def test_history_exact_peer_store_dedup_and_no_bodies(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            msg={'store':'ordinary','id':'one','peer_identity':'agent-demo','local_identity':'agent-owner','date':'2026-10-11T12:00:00Z','direction':'inbound','text':'DO NOT EXPOSE THIS'}
            share={'privacy':'metadata-only','messages':[msg,msg,{**msg,'store':'private-store','id':'other'},{**msg,'id':'two','peer_identity':'someone-else'},{**msg,'id':'three','local_identity':'custom-private'}], 'private_contours':[{'local_identity':'custom-private','peer_identity':'private-peer'}]}
            (root/'share-data.json').write_text(json.dumps(share))
            result=Q.contact_history('agent-demo',root,{'ordinary':None})
            self.assertEqual(result['total'],1);self.assertEqual(result['matches'][0]['id'],'one')
            self.assertNotIn('DO NOT EXPOSE',json.dumps(result))
            for peer in ('private-peer','agent-viola-alex','../../bad'):
                with self.assertRaises(ValueError):Q.contact_history(peer,root,{'ordinary':None})
            share['privacy']='public';(root/'share-data.json').write_text(json.dumps(share))
            with self.assertRaises(ValueError):Q.contact_history('agent-demo',root,{'ordinary':None})

    def test_history_bounded(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'share-data.json').write_text(json.dumps({'privacy':'metadata-only','messages':[{'id':str(i),'store':'ordinary','peer_identity':'agent-demo','date':f'2026-10-11T12:00:{i:02d}Z'} for i in range(55)]}))
            r=Q.contact_history('agent-demo',root,{'ordinary':None});self.assertEqual(len(r['matches']),40);self.assertEqual(r['total'],55);self.assertTrue(r['truncated'])

if __name__=='__main__':unittest.main()
