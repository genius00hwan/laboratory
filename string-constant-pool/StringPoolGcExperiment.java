package org.example.stringpool;


import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.List;

import java.lang.ref.Reference;
import java.lang.ref.ReferenceQueue;

public class StringPoolGcExperiment {

    private static final ReferenceQueue<String> refQ = new ReferenceQueue<>();

    private static class NamedWeakRef extends WeakReference<String> {
        private final String name;

        public NamedWeakRef(String name, String referent, ReferenceQueue<String> q) {
            super(referent, q);
            this.name = name;
        }

        public String name() {
            return name;
        }
    }

    public static void main(String[] args) throws Exception {
        System.out.println("===== 1. 원본 실험 =====");
        originalExperiment();

        System.out.println();
        System.out.println("===== 2. 보완 실험 =====");
        dynamicInternExperiment();
    }

    private static void originalExperiment() throws Exception {
        String lit = "Literal";                // 리터럴
        String heap = new String("Heap");      // 힙에 저장되는 일반 객체
        String internObj = new String("Intern");
        String pooled = internObj.intern();    // String Pool에 저장된 intern된 문자열

        NamedWeakRef litRef = new NamedWeakRef("리터럴", lit, refQ);
        NamedWeakRef heapRef = new NamedWeakRef("new String(\"Heap\")", heap, refQ);
        NamedWeakRef internRef = new NamedWeakRef("intern 호출 전 힙 객체", internObj, refQ);
        NamedWeakRef pooledRef = new NamedWeakRef("intern() 반환 풀 객체", pooled, refQ);

        printAlive("GC 전", litRef, heapRef, internRef, pooledRef);

        lit = null;
        heap = null;
        internObj = null;
        pooled = null;

        forceGC();

        printAlive("GC 후", litRef, heapRef, internRef, pooledRef);
        drainReferenceQueue();
    }

    private static void dynamicInternExperiment() throws Exception {
        // 소스코드에 동일한 "완성 문자열 리터럴"이 직접 등장하지 않도록 동적으로 생성
        String dynamic = new StringBuilder()
            .append("dyn-")
            .append(System.nanoTime())
            .toString();

        String pooled = dynamic.intern();

        NamedWeakRef dynamicRef = new NamedWeakRef("동적 문자열 원본", dynamic, refQ);
        NamedWeakRef pooledRef = new NamedWeakRef("동적 문자열 intern() 결과", pooled, refQ);

        System.out.println("동적 문자열 값: " + pooled);
        System.out.println("dynamic == pooled ? " + (dynamic == pooled));

        printAlive("GC 전", dynamicRef, pooledRef);

        dynamic = null;
        pooled = null;

        forceGC();

        printAlive("GC 후", dynamicRef, pooledRef);
        drainReferenceQueue();
    }

    private static void printAlive(String phase, NamedWeakRef... refs) {
        for (NamedWeakRef ref : refs) {
            System.out.println(phase + ": " + ref.name() + " 살아있니~? " + (ref.get() != null));
        }
    }

    private static void drainReferenceQueue() {
        Reference<? extends String> ref;
        while ((ref = refQ.poll()) != null) {
            NamedWeakRef named = (NamedWeakRef) ref;
            System.out.println("ReferenceQueue 감지: [" + named.name() + "] GC됨");
        }
    }

    private static void forceGC() throws InterruptedException {
        // System.gc()는 보장이 아니므로 여러 번 시도
        for (int round = 0; round < 10; round++) {
            System.gc();
            System.runFinalization();

            // 약한 메모리 압박
            List<byte[]> pressure = new ArrayList<>();
            try {
                for (int i = 0; i < 8; i++) {
                    pressure.add(new byte[1024 * 1024]); // 1MB * 8
                }
            } catch (OutOfMemoryError ignored) {
                // 일부 환경에선 메모리가 작을 수 있으니 무시
            }

            Thread.sleep(100);
        }
    }
}